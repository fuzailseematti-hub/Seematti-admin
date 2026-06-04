import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";
import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";

// Scheduled report emails (pg_cron -> pg_net). Builds the report from the DB and
// sends via Resend, optionally attaching a PDF and/or CSV (per automation). Set
// RESEND_API_KEY (and RESEND_FROM once the domain is verified) as edge secrets.
const FROM = Deno.env.get("RESEND_FROM") || "Seematti Reports <onboarding@resend.dev>";
const IST = "Asia/Kolkata";
const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

const TONE: Record<string, string> = { present: "#0E7C3A", late: "#B8860B", on_leave: "#2B6CB0", absent: "#C0392B", leave: "#2B6CB0" };
const SLABEL: Record<string, string> = { present: "Present", late: "Late", on_leave: "On leave", absent: "Absent" };

// Seemaatti logo, served by the app. Fetched once and cached for the PDF header;
// the email references the same public URL directly.
const LOGO_URL = "https://seematti-admin.vercel.app/assets/seemaatti-logo.png";
let LOGO_CACHE: Uint8Array | null = null;
async function getLogo(): Promise<Uint8Array | null> {
  if (LOGO_CACHE) return LOGO_CACHE;
  try { const r = await fetch(LOGO_URL); if (r.ok) LOGO_CACHE = new Uint8Array(await r.arrayBuffer()); } catch (_) { /* fall back to text */ }
  return LOGO_CACHE;
}

// ── date/util helpers ───────────────────────────────────────────────────────
const istParts = () => {
  const now = new Date();
  const date = new Intl.DateTimeFormat("en-CA", { timeZone: IST, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
  const time = new Intl.DateTimeFormat("en-GB", { timeZone: IST, hour: "2-digit", minute: "2-digit", hour12: false }).format(now);
  return { date, time };
};
const longDate = (iso: string) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: IST, weekday: "long", day: "2-digit", month: "long", year: "numeric" })
    .format(new Date(iso + "T06:00:00Z"));
const addDays = (iso: string, n: number) => { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const esc = (s: unknown) => String(s ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));
const hhmm = (t: unknown) => (t ? String(t).slice(0, 5) : "—");

async function loadCommon() {
  const [emp, sec] = await Promise.all([
    sb.from("employees").select("id, name, section_id, user_type, is_active, gender").eq("is_active", true).neq("user_type", "owner"),
    sb.from("sections").select("id, name, sort_order").order("sort_order"),
  ]);
  return { emps: emp.data || [], sections: sec.data || [] };
}
const WOMAN_SET = ["female", "f", "woman", "women", "ladies", "lady"];
function sectionGroups(emps: any[], sections: any[]) {
  const order: string[] = sections.map((s) => s.id);
  const label: Record<string, string> = {}; sections.forEach((s) => label[s.id] = s.name);
  const groups: Record<string, any[]> = {};
  emps.forEach((e) => { const k = e.section_id || "__none"; (groups[k] = groups[k] || []).push(e); });
  const keys = Object.keys(groups).sort((a, b) => (order.indexOf(a) < 0 ? 999 : order.indexOf(a)) - (order.indexOf(b) < 0 ? 999 : order.indexOf(b)));
  return keys.map((k) => ({ id: k, label: label[k] || (k === "__none" ? "No section" : k), list: groups[k] }));
}

// ── report models (plain data; rendered to html / csv / pdf below) ──────────
async function dailyModel(offset = 0, opts: any = {}) {
  const { date: today } = istParts();
  const date = addDays(today, offset);
  const { emps, sections } = await loadCommon();
  const [att, lv, fl, setRes] = await Promise.all([
    sb.from("attendance").select("employee_id, status, punch_in_time, punch_out_time").eq("date", date),
    sb.from("leave_requests").select("employee_id, from_date, days, type, status").eq("status", "approved").lte("from_date", date).gte("from_date", addDays(date, -60)),
    sb.from("free_leaves").select("employee_id").eq("leave_date", date),
    sb.from("settings").select("key, value").in("key", ["checkin_start", "early_cutoff_men", "early_cutoff_women"]),
  ]);
  const cs: any = { checkin_start: "08:00", early_cutoff_men: "22:00", early_cutoff_women: "20:00" };
  (setRes.data || []).forEach((r: any) => cs[r.key] = r.value);
  const startB = String(cs.checkin_start || "08:00").slice(0, 5);

  const attBy: Record<string, any> = {}; (att.data || []).forEach((a) => attBy[a.employee_id] = a);
  const leaveBy: Record<string, string> = {};
  (lv.data || []).forEach((l) => { const end = addDays(l.from_date, Math.max(0, (Number(l.days) || 1) - 1)); if (date >= l.from_date && date <= end) leaveBy[l.employee_id] = l.type || "Leave"; });
  const freeBy: Record<string, boolean> = {}; (fl.data || []).forEach((f) => freeBy[f.employee_id] = true);
  const totals: any = { present: 0, late: 0, on_leave: 0, absent: 0, early: 0 };
  const rank: any = { present: 0, late: 1, on_leave: 2, absent: 3 };

  const sects = sectionGroups(emps, sections).map((sec) => {
    const rows = sec.list.map((e: any) => {
      const a = attBy[e.id]; let st: string, lt = "";
      if (a && (a.status === "present" || a.status === "late")) st = a.status;
      else if (leaveBy[e.id] || a?.status === "on_leave") { st = "on_leave"; lt = leaveBy[e.id] || "Leave"; }
      else if (freeBy[e.id]) { st = "on_leave"; lt = "Free leave"; }
      else st = "absent";
      totals[st]++;
      const out5 = a?.punch_out_time ? String(a.punch_out_time).slice(0, 5) : null;
      const closeCut = String((WOMAN_SET.includes(String(e.gender || "").toLowerCase()) ? cs.early_cutoff_women : cs.early_cutoff_men) || "").slice(0, 5);
      const early = !!(out5 && (st === "present" || st === "late") && out5 >= startB && closeCut && out5 < closeCut);
      if (early) totals.early++;
      const statusText = st === "on_leave" && lt ? `On leave (${lt})` : SLABEL[st];
      return { id: e.id, name: e.name, st, statusText, tone: TONE[st], in: hhmm(a?.punch_in_time), out: hhmm(a?.punch_out_time), early };
    }).sort((a: any, b: any) => rank[a.st] - rank[b.st] || a.name.localeCompare(b.name));
    const c: any = { present: 0, late: 0, on_leave: 0, absent: 0, early: 0 };
    rows.forEach((r: any) => { c[r.st]++; if (r.early) c.early++; });
    const meta = `${rows.length} staff · ${c.present} present, ${c.late} late, ${c.on_leave} leave, ${c.absent} absent${c.early ? `, ${c.early} left early` : ""}`;
    return { label: sec.label, meta, rows };
  });
  const total = (totals.present + totals.late + totals.on_leave + totals.absent);
  const subject = `${opts.subjectLabel || "Daily attendance"} — ${date}`;
  const title = opts.title || "Daily Attendance Report";
  const fileBase = `${opts.fileBase || "daily-attendance"}-${date}`;
  const summary = `Total ${total}   Present ${totals.present}   Late ${totals.late}   On leave ${totals.on_leave}   Absent ${totals.absent}   Left early ${totals.early}`;

  // Previous-day report: ONE landscape table per section — every employee on a
  // single line, including outpass times and total time inside the showroom.
  if (opts.withOutpass) {
    const RED = "#C0392B", AMBER = "#C97A1A";
    const ev = await sb.from("attendance_events")
      .select("employee_id, event_type, at, seq").eq("shift_date", date).order("seq");
    const byEmp: Record<string, any[]> = {};
    (ev.data || []).forEach((e: any) => { (byEmp[e.employee_id] = byEmp[e.employee_id] || []).push(e); });
    const toMin = (t: string) => { const [h, m] = String(t).slice(0, 5).split(":").map(Number); return h * 60 + m; };
    const fmtDur = (mn: number) => `${Math.floor(mn / 60)}h ${String(mn % 60).padStart(2, "0")}m`;
    let outpassCount = 0;

    const consSections = sects.map((sec) => ({
      label: sec.label, meta: sec.meta,
      rows: sec.rows.map((r: any) => {
        const evs = byEmp[r.id] || [];
        const ops: any[] = []; let openOut: any = null; let openFlag = false;
        for (const x of evs) {
          if (x.event_type === "outpass_out") { if (openOut) openFlag = true; openOut = x; }
          else if (x.event_type === "outpass_in") { if (openOut) { ops.push({ out: String(openOut.at).slice(0, 5), in: String(x.at).slice(0, 5) }); openOut = null; } }
        }
        if (openOut) { openFlag = true; ops.push({ out: String(openOut.at).slice(0, 5), in: null }); }
        outpassCount += ops.length;
        const outMins = ops.reduce((s, o) => s + (o.in ? Math.max(0, toMin(o.in) - toMin(o.out)) : 0), 0);
        const inT = r.in !== "—" ? r.in : null;
        const outT = r.out !== "—" ? r.out : null;
        const hasIn = !!inT || evs.some((x: any) => x.event_type === "check_in");
        const incomplete = hasIn && (!inT || !outT || openFlag);
        const inside = (hasIn && inT && outT && !openFlag) ? Math.max(0, toMin(outT) - toMin(inT) - outMins) : null;
        const opTimes = ops.map((o) => `${o.out}-${o.in || "…"}`).join(", ");
        return [
          { t: r.name },
          { t: r.statusText, c: r.tone },
          { t: r.in, c: r.st === "late" ? RED : undefined },
          { t: r.early ? `${r.out} early` : r.out, c: r.early ? RED : undefined },
          { t: ops.length ? `${ops.length} · ${fmtDur(outMins)}` : "—", c: ops.length ? AMBER : undefined },
          { t: opTimes },
          { t: incomplete ? "Incomplete" : (inside != null ? fmtDur(inside) : "—"), c: incomplete ? RED : undefined },
        ];
      }),
    }));

    return {
      kind: "daily", subject, title, dateLabel: longDate(date),
      summary: `${summary}   Outpasses ${outpassCount}`,
      fileBase, landscape: true,
      columns: [
        { header: "Employee", x: 36, max: 26 },
        { header: "Status", x: 232, max: 14 },
        { header: "In", x: 332, max: 8 },
        { header: "Out", x: 382, max: 11 },
        { header: "Outpass", x: 452, max: 12 },
        { header: "Outpass times", x: 532, max: 30 },
        { header: "Time inside", x: 740, max: 12 },
      ],
      sections: consSections,
    };
  }

  return {
    kind: "daily", subject, title, dateLabel: longDate(date), summary, fileBase,
    columns: [
      { header: "Employee", x: 44, max: 34 },
      { header: "Status", x: 272, max: 22 },
      { header: "Check in", x: 398, max: 8 },
      { header: "Check out", x: 466, max: 16 },
    ],
    sections: sects.map((s) => ({
      label: s.label, meta: s.meta,
      rows: s.rows.map((r: any) => [
        { t: r.name },
        { t: r.statusText, c: r.tone },
        { t: r.in, c: r.st === "late" ? "#C0392B" : undefined },
        { t: r.early ? `${r.out} early` : r.out, c: r.early ? "#C0392B" : undefined },
      ]),
    })),
  };
}

async function leaveModel() {
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
  const sects = sectionGroups(leaveEmps, sections).filter((s) => s.list.length).map((sec) => {
    const rows = sec.list.map((e: any) => [{ t: e.name }, { t: onLeave[e.id], c: TONE.leave }]);
    return { label: `${sec.label} (${sec.list.length})`, meta: "", rows };
  });
  return {
    kind: "leave",
    subject: `Leave tomorrow (${target}) — ${leaveEmps.length} staff`,
    title: "Next-Day Leave Report",
    dateLabel: longDate(target),
    summary: `${leaveEmps.length} staff on leave`,
    fileBase: `leave-${target}`,
    columns: [
      { header: "Employee", x: 44, max: 46 },
      { header: "Leave type", x: 340, max: 28 },
    ],
    sections: sects,
  };
}

// ── renderers ───────────────────────────────────────────────────────────────
function htmlFrom(m: any): string {
  let body = "";
  if (!m.sections.length) body = `<p style="font-size:14px;color:#444">Nothing to report.</p>`;
  for (const sec of m.sections) {
    body += `<h3 style="margin:18px 0 4px;font-family:Georgia,serif">${esc(sec.label)}${sec.meta ? ` <span style="font-size:11px;color:#888;font-weight:normal">· ${esc(sec.meta)}</span>` : ""}</h3>`;
    body += `<table style="width:100%;border-collapse:collapse;font-size:13px"><tr style="color:#777;text-align:left">${m.columns.map((c: any) => `<th style="padding:4px 8px;font-weight:600">${esc(c.header)}</th>`).join("")}</tr>`;
    body += sec.rows.map((r: any) => `<tr style="border-top:1px solid #eee">${r.map((cell: any) => `<td style="padding:4px 8px;${cell.c ? `color:${cell.c};font-weight:600` : ""}">${esc(cell.t)}</td>`).join("")}</tr>`).join("");
    body += `</table>`;
  }
  for (const t of (m.extraTables || [])) {
    body += `<h3 style="margin:22px 0 4px;font-family:Georgia,serif">${esc(t.title)}</h3>`;
    body += `<table style="width:100%;border-collapse:collapse;font-size:13px"><tr style="color:#777;text-align:left">${t.columns.map((c: any) => `<th style="padding:4px 8px;font-weight:600">${esc(c.header)}</th>`).join("")}</tr>`;
    body += t.rows.map((r: any) => `<tr style="border-top:1px solid #eee">${r.map((cell: any) => `<td style="padding:4px 8px;${cell.c ? `color:${cell.c};font-weight:600` : ""}">${esc(cell.t)}</td>`).join("")}</tr>`).join("");
    body += `</table>`;
  }
  return `<div style="font-family:Arial,Helvetica,sans-serif;color:#111;max-width:${m.landscape ? 1040 : 680}px">
    <img src="${LOGO_URL}" alt="Seemaatti" height="42" style="display:block;height:42px;margin-bottom:8px;border:0" />
    <h2 style="font-family:Georgia,serif;margin:4px 0 2px">${esc(m.title)}</h2>
    <div style="font-size:13px;color:#666">${esc(m.dateLabel)}</div>
    <p style="font-size:14px;font-weight:600;margin:12px 0 4px">${esc(m.summary)}</p>${body}
    <p style="font-size:11px;color:#999;margin-top:20px">Sent automatically by Seemaatti Admin.</p>
  </div>`;
}

function csvFrom(m: any): string {
  const q = (v: unknown) => { const s = String(v ?? ""); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  const header = ["Section", ...m.columns.map((c: any) => c.header)];
  const lines = [header.map(q).join(",")];
  for (const sec of m.sections) {
    const secName = sec.label.replace(/\s*\(\d+\)\s*$/, "");
    for (const r of sec.rows) lines.push([secName, ...r.map((cell: any) => cell.t)].map(q).join(","));
  }
  for (const t of (m.extraTables || [])) {
    lines.push("");
    lines.push(q(t.title));
    lines.push(t.columns.map((c: any) => q(c.header)).join(","));
    for (const r of t.rows) lines.push(r.map((cell: any) => q(cell.t)).join(","));
  }
  return lines.join("\r\n");
}

const hexRgb = (hex: string) => {
  const h = hex.replace("#", "");
  return rgb(parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255);
};

async function pdfFrom(m: any): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  const landscape = !!m.landscape;
  const W = landscape ? 841.89 : 595.28, H = landscape ? 595.28 : 841.89, M = landscape ? 36 : 44;
  const INK = rgb(0.10, 0.10, 0.12), MUTE = rgb(0.42, 0.42, 0.46), RULE = rgb(0.86, 0.86, 0.88), MAROON = rgb(0.43, 0.11, 0.13);
  let page = doc.addPage([W, H]); let y = H - M; let pageNo = 1;
  const clip = (s: unknown, n: number) => { const str = String(s ?? ""); return str.length > n ? str.slice(0, n - 1) + "." : str; };
  const txt = (s: unknown, x: number, size: number, f = font, color = INK) => page.drawText(String(s), { x, y, size, font: f, color });
  const rule = () => page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.5, color: RULE });
  const footer = () => {
    page.drawText("Generated by Seemaatti Admin · " + m.dateLabel, { x: M, y: 26, size: 7.5, font, color: MUTE });
    const p = "Page " + pageNo; page.drawText(p, { x: W - M - font.widthOfTextAtSize(p, 7.5), y: 26, size: 7.5, font, color: MUTE });
  };
  const newPage = () => { footer(); page = doc.addPage([W, H]); y = H - M; pageNo++; };
  const need = (h: number) => { if (y - h < 52) newPage(); };
  const colHeader = (cols: any[]) => { cols.forEach((c: any) => txt(c.header, c.x, 7.5, bold, MUTE)); y -= 6; rule(); y -= 12; };
  const drawRows = (cols: any[], rows: any[]) => {
    for (const r of rows) {
      need(15);
      r.forEach((cell: any, i: number) => txt(clip(cell.t, cols[i].max), cols[i].x, 9.5, font, cell.c ? hexRgb(cell.c) : INK));
      y -= 14;
      // Faint divider, placed clear of both rows (avoids cutting through text).
      if (landscape) page.drawLine({ start: { x: M, y: y + 9 }, end: { x: W - M, y: y + 9 }, thickness: 0.3, color: rgb(0.92, 0.92, 0.93) });
    }
  };

  const logoBytes = await getLogo();
  let placed = false;
  if (logoBytes) {
    try {
      const logo = await doc.embedPng(logoBytes);
      const lw = 124, lh = lw * logo.height / logo.width;
      page.drawImage(logo, { x: M, y: y - lh + 4, width: lw, height: lh });
      y -= (lh + 22); placed = true;
    } catch (_) { /* fall back to text */ }
  }
  if (!placed) { txt("SEEMAATTI", M, 11, bold, MAROON); y -= 20; }
  txt(m.title, M, 19, bold); y -= 18;
  txt(m.dateLabel, M, 10.5, font, MUTE); y -= 22;
  txt(m.summary, M, 10.5, bold, INK); y -= 12; rule(); y -= 22;

  if (!m.sections.length) { txt("Nothing to report.", M, 11, font, MUTE); y -= 16; }
  for (const sec of m.sections) {
    need(60);
    txt(sec.label, M, 13, bold);
    if (sec.meta) txt(sec.meta, W - M - font.widthOfTextAtSize(sec.meta, 8.5), 8.5, font, MUTE);
    y -= 16; colHeader(m.columns);
    drawRows(m.columns, sec.rows);
    y -= 14;
  }
  for (const t of (m.extraTables || [])) {
    need(80);
    y -= 6;
    txt(t.title, M, 13, bold);
    y -= 16; colHeader(t.columns);
    drawRows(t.columns, t.rows);
    y -= 14;
  }
  footer();
  return await doc.save();
}

async function sendEmail(to: string[], subject: string, html: string, attachments: any[]) {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) return { skipped: "RESEND_API_KEY not set" };
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to, subject, html, ...(attachments.length ? { attachments } : {}) }),
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
    let model: any;
    try {
      if (a.type === "next_day_leave") model = await leaveModel();
      else if (a.type === "prev_day_attendance") model = await dailyModel(-1, { subjectLabel: "Previous-day attendance", title: "Previous Day Attendance (In / Out)", fileBase: "attendance", withOutpass: true });
      else model = await dailyModel(0);
    } catch (e) { results.push({ id: a.id, error: String(e) }); continue; }

    const fmt = a.attach_format || "none";
    const attachments: any[] = [];
    try {
      if (fmt === "pdf" || fmt === "both") attachments.push({ filename: `${model.fileBase}.pdf`, content: encodeBase64(await pdfFrom(model)) });
      if (fmt === "csv" || fmt === "both") attachments.push({ filename: `${model.fileBase}.csv`, content: encodeBase64(new TextEncoder().encode(csvFrom(model))) });
    } catch (e) { results.push({ id: a.id, error: "attachment: " + String(e) }); continue; }

    const sent: any = await sendEmail(a.recipients, model.subject, htmlFrom(model), attachments);
    if (!sent.skipped && sent.status && sent.status < 300) {
      await sb.from("automations").update({ last_sent_on: date, updated_at: new Date().toISOString() }).eq("id", a.id);
    }
    results.push({ id: a.id, type: a.type, attach: fmt, sent });
  }
  return new Response(JSON.stringify({ ran_at: `${date} ${time}`, results }, null, 2), { headers: { "content-type": "application/json" } });
});
