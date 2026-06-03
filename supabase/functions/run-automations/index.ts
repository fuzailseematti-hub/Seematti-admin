import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

// Runs on a schedule (pg_cron -> pg_net). Finds due automations and emails the
// requested report via Resend. Gated by an internal cron secret stored in
// public.app_config (read with the service role). Set RESEND_API_KEY as an
// edge-function secret to enable sending (see docs/email-automation-setup.md).
const FROM = "Seematti Reports <reports@seematti.app>";
const IST = "Asia/Kolkata";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

const istParts = () => {
  const now = new Date();
  const date = new Intl.DateTimeFormat("en-CA", { timeZone: IST, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
  const time = new Intl.DateTimeFormat("en-GB", { timeZone: IST, hour: "2-digit", minute: "2-digit", hour12: false }).format(now);
  return { date, time };
};
const addDays = (iso: string, n: number) => { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const esc = (s: unknown) => String(s ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));
const hhmm = (t: unknown) => (t ? String(t).slice(0, 5) : "—");

async function loadCommon() {
  const [emp, sec] = await Promise.all([
    sb.from("employees").select("id, name, section_id, user_type, is_active").eq("is_active", true).neq("user_type", "owner"),
    sb.from("sections").select("id, name, sort_order").order("sort_order"),
  ]);
  return { emps: emp.data || [], sections: sec.data || [] };
}
function sectionGroups(emps: any[], sections: any[]) {
  const order: string[] = sections.map((s) => s.id);
  const label: Record<string, string> = {}; sections.forEach((s) => label[s.id] = s.name);
  const groups: Record<string, any[]> = {};
  emps.forEach((e) => { const k = e.section_id || "__none"; (groups[k] = groups[k] || []).push(e); });
  const keys = Object.keys(groups).sort((a, b) => (order.indexOf(a) < 0 ? 999 : order.indexOf(a)) - (order.indexOf(b) < 0 ? 999 : order.indexOf(b)));
  return keys.map((k) => ({ id: k, label: label[k] || (k === "__none" ? "No section" : k), list: groups[k] }));
}

async function dailyAttendanceHtml() {
  const { date } = istParts();
  const { emps, sections } = await loadCommon();
  const [att, lv, fl] = await Promise.all([
    sb.from("attendance").select("employee_id, status, punch_in_time, punch_out_time").eq("date", date),
    sb.from("leave_requests").select("employee_id, from_date, days, type, status").eq("status", "approved").lte("from_date", date).gte("from_date", addDays(date, -60)),
    sb.from("free_leaves").select("employee_id").eq("leave_date", date),
  ]);
  const attBy: Record<string, any> = {}; (att.data || []).forEach((a) => attBy[a.employee_id] = a);
  const leaveBy: Record<string, string> = {};
  (lv.data || []).forEach((l) => { const end = addDays(l.from_date, Math.max(0, (Number(l.days) || 1) - 1)); if (date >= l.from_date && date <= end) leaveBy[l.employee_id] = l.type || "Leave"; });
  const freeBy: Record<string, boolean> = {}; (fl.data || []).forEach((f) => freeBy[f.employee_id] = true);
  const totals: any = { present: 0, late: 0, on_leave: 0, absent: 0 };
  const rowFor = (e: any) => {
    const a = attBy[e.id]; let status: string, lt = "";
    if (a && (a.status === "present" || a.status === "late")) status = a.status;
    else if (leaveBy[e.id] || a?.status === "on_leave") { status = "on_leave"; lt = leaveBy[e.id] || "Leave"; }
    else if (freeBy[e.id]) { status = "on_leave"; lt = "Free leave"; }
    else status = "absent";
    totals[status]++;
    return { name: e.name, status, lt, in: a?.punch_in_time, out: a?.punch_out_time };
  };
  const order: any = { present: 0, late: 1, on_leave: 2, absent: 3 };
  const badge: Record<string, string> = { present: "#0E7C3A", late: "#B8860B", on_leave: "#2B6CB0", absent: "#C0392B" };
  const slabel: Record<string, string> = { present: "Present", late: "Late", on_leave: "On leave", absent: "Absent" };
  let body = "";
  for (const sec of sectionGroups(emps, sections)) {
    const rows = sec.list.map(rowFor).sort((a: any, b: any) => order[a.status] - order[b.status] || a.name.localeCompare(b.name));
    body += `<h3 style="margin:18px 0 6px;font-family:Georgia,serif">${esc(sec.label)}</h3><table style="width:100%;border-collapse:collapse;font-size:13px"><tr style="color:#666;text-align:left"><th style="padding:4px 8px">Employee</th><th>Status</th><th>In</th><th>Out</th></tr>`;
    body += rows.map((r: any) => `<tr style="border-top:1px solid #eee"><td style="padding:4px 8px">${esc(r.name)}</td><td><span style="color:${badge[r.status]};font-weight:600">${slabel[r.status]}${r.status === "on_leave" && r.lt ? " · " + esc(r.lt) : ""}</span></td><td>${hhmm(r.in)}</td><td>${hhmm(r.out)}</td></tr>`).join("");
    body += "</table>";
  }
  const summary = `<p style="font-size:14px">Present <b>${totals.present}</b> · Late <b>${totals.late}</b> · On leave <b>${totals.on_leave}</b> · Absent <b>${totals.absent}</b></p>`;
  return { subject: `Daily attendance — ${date}`, html: `<div style="font-family:Arial,sans-serif;color:#111"><h2 style="font-family:Georgia,serif">Daily attendance — ${date}</h2>${summary}${body}</div>` };
}

async function nextDayLeaveHtml() {
  const { date } = istParts();
  const target = addDays(date, 1);
  const { emps, sections } = await loadCommon();
  const [lv, fl] = await Promise.all([
    sb.from("leave_requests").select("employee_id, from_date, days, type, status").eq("status", "approved").lte("from_date", target).gte("from_date", addDays(target, -60)),
    sb.from("free_leaves").select("employee_id").eq("leave_date", target),
  ]);
  const onLeave: Record<string, string> = {};
  (lv.data || []).forEach((l) => { const end = addDays(l.from_date, Math.max(0, (Number(l.days) || 1) - 1)); if (target >= l.from_date && target <= end) onLeave[l.employee_id] = l.type || "Leave"; });
  (fl.data || []).forEach((f) => { if (!onLeave[f.employee_id]) onLeave[f.employee_id] = "Free leave"; });
  const leaveEmps = emps.filter((e) => onLeave[e.id]);
  let body = "", count = 0;
  for (const sec of sectionGroups(leaveEmps, sections)) {
    if (!sec.list.length) continue;
    body += `<h3 style="margin:16px 0 4px;font-family:Georgia,serif">${esc(sec.label)} (${sec.list.length})</h3><ul style="margin:0;padding-left:18px;font-size:14px">`;
    body += sec.list.map((e) => { count++; return `<li>${esc(e.name)} <span style="color:#2B6CB0">· ${esc(onLeave[e.id])}</span></li>`; }).join("");
    body += "</ul>";
  }
  if (!count) body = `<p>No one is on leave on ${target}.</p>`;
  return { subject: `Leave tomorrow (${target}) — ${count} staff`, html: `<div style="font-family:Arial,sans-serif;color:#111"><h2 style="font-family:Georgia,serif">Leave tomorrow — ${target}</h2><p style="font-size:14px"><b>${count}</b> on leave</p>${body}</div>` };
}

async function sendEmail(to: string[], subject: string, html: string) {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) return { skipped: "RESEND_API_KEY not set" };
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to, subject, html }),
  });
  return { status: res.status, body: (await res.text()).slice(0, 300) };
}

Deno.serve(async (req) => {
  const { data: cfg } = await sb.from("app_config").select("value").eq("key", "cron_secret").maybeSingle();
  if (!cfg || req.headers.get("x-cron-secret") !== cfg.value) {
    return new Response(JSON.stringify({ error: "forbidden" }), { status: 403, headers: { "content-type": "application/json" } });
  }
  const { date, time } = istParts();
  const { data: autos } = await sb.from("automations").select("*").eq("enabled", true);
  const results: any[] = [];
  for (const a of autos || []) {
    const due = (!a.last_sent_on || a.last_sent_on < date) && time >= String(a.send_time).slice(0, 5);
    if (!due) { results.push({ id: a.id, skipped: "not due" }); continue; }
    if (!a.recipients || !a.recipients.length) { results.push({ id: a.id, skipped: "no recipients" }); continue; }
    let rep;
    try { rep = a.type === "next_day_leave" ? await nextDayLeaveHtml() : await dailyAttendanceHtml(); }
    catch (e) { results.push({ id: a.id, error: String(e) }); continue; }
    const sent: any = await sendEmail(a.recipients, rep.subject, rep.html);
    if (!sent.skipped && sent.status && sent.status < 300) {
      await sb.from("automations").update({ last_sent_on: date, updated_at: new Date().toISOString() }).eq("id", a.id);
    }
    results.push({ id: a.id, type: a.type, sent });
  }
  return new Response(JSON.stringify({ ran_at: `${date} ${time}`, results }, null, 2), { headers: { "content-type": "application/json" } });
});
