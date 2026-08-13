/*
 * Seemaatti ADMS bridge — Cloudflare Worker
 *
 * The ESSL uFace302 pushes attendance over plain HTTP (ADMS protocol,
 * fixed /iclock/* paths). This worker is the HTTP endpoint the device
 * points at; it forwards every punch to Supabase over HTTPS via the
 * adms_ingest() RPC. All attendance rules live in the database — this
 * file only translates the device's wire format.
 *
 * Env vars (set via `wrangler secret put` / dashboard):
 *   SUPABASE_URL       e.g. https://hixhbznbejqfnasvgyid.supabase.co
 *   SUPABASE_ANON_KEY  the project's anon key
 *   ADMS_SECRET        must equal settings.adms_secret in the database
 */

const TEXT = { 'Content-Type': 'text/plain' };

async function rpc(env, fn, body) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: env.SUPABASE_ANON_KEY,
      Authorization: `Bearer ${env.SUPABASE_ANON_KEY}`,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${fn} -> HTTP ${res.status}: ${await res.text()}`);
  return res.json().catch(() => null);
}

// ATTLOG body: one punch per line, tab-separated:
//   <user id> \t <YYYY-MM-DD HH:MM:SS> \t <status> \t <verify> [\t ...]
function parseAttlog(body) {
  const punches = [];
  for (const line of body.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    const f = t.split('\t');
    if (f.length < 2 || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(f[1])) continue;
    punches.push({
      user_id: f[0].trim(),
      time: f[1].trim(),
      status: Number.isFinite(parseInt(f[2], 10)) ? parseInt(f[2], 10) : null,
      verify: Number.isFinite(parseInt(f[3], 10)) ? parseInt(f[3], 10) : null,
      raw: t.slice(0, 500),
    });
  }
  return punches;
}

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    // ESSL firmware variants call /iclock/cdata.aspx — treat both the
    // same.
    const path = url.pathname.replace(/\.aspx$/i, '');
    const sn = url.searchParams.get('SN') || '';

    if (!path.startsWith('/iclock/')) return new Response('Seemaatti ADMS bridge', { headers: TEXT });

    // Initial handshake: device asks for its configuration.
    if (path === '/iclock/cdata' && req.method === 'GET') {
      const reply = [
        `GET OPTION FROM: ${sn}`,
        'ATTLOGStamp=None',
        'OPERLOGStamp=None',
        'ATTPHOTOStamp=None',
        'ErrorDelay=30',
        'Delay=10',
        'TransTimes=00:00;12:00',
        'TransInterval=1',
        'TransFlag=1100000000',
        'TimeZone=5.5',
        'Realtime=1',
        'Encrypt=None',
      ].join('\n');
      ctx.waitUntil(rpc(env, 'adms_heartbeat', { p_secret: env.ADMS_SECRET, p_sn: sn }).catch(() => {}));
      return new Response(reply, { headers: TEXT });
    }

    // Data upload: attendance punches (table=ATTLOG) and everything else.
    if (path === '/iclock/cdata' && req.method === 'POST') {
      const table = url.searchParams.get('table') || '';
      const body = await req.text();
      if (table !== 'ATTLOG') {
        // User records, fingerprints, op-logs, query results — store raw.
        ctx.waitUntil(rpc(env, 'adms_store_upload', {
          p_secret: env.ADMS_SECRET, p_sn: sn, p_kind: table || 'unknown', p_body: body,
        }).catch(() => {}));
        return new Response('OK', { headers: TEXT });
      }

      const punches = parseAttlog(body);
      let ok = 0;
      for (const p of punches) {
        try {
          await rpc(env, 'adms_ingest', {
            p_secret: env.ADMS_SECRET,
            p_sn: sn,
            p_user_id: p.user_id,
            p_time: p.time,
            p_status: p.status,
            p_verify: p.verify,
            p_raw: p.raw,
          });
          ok++;
        } catch (e) {
          // Leave the batch unacknowledged count intact; the device
          // re-sends unacked logs, and adms_ingest is replay-proof.
          console.log(`ingest failed: ${e.message}`);
        }
      }
      // Acknowledge only what landed — the device retries the rest.
      return new Response(`OK: ${ok}`, { headers: TEXT });
    }

    // Command poll — doubles as the device heartbeat. Returns either
    // 'OK' (nothing queued) or 'C:<id>:<command>' from the queue.
    if (path === '/iclock/getrequest') {
      try {
        const next = await rpc(env, 'adms_next_command', { p_secret: env.ADMS_SECRET, p_sn: sn });
        return new Response(typeof next === 'string' && next ? next : 'OK', { headers: TEXT });
      } catch (_) {
        return new Response('OK', { headers: TEXT });
      }
    }

    // Command results from the device.
    if (path === '/iclock/devicecmd' && req.method === 'POST') {
      const body = await req.text();
      ctx.waitUntil(rpc(env, 'adms_store_upload', {
        p_secret: env.ADMS_SECRET, p_sn: sn, p_kind: 'devicecmd', p_body: body,
      }).catch(() => {}));
      return new Response('OK', { headers: TEXT });
    }

    // Anything else in the protocol: acknowledge.
    return new Response('OK', { headers: TEXT });
  },
};
