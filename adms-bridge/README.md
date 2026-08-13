# ADMS bridge (ESSL uFace302 → Supabase)

The uFace302 pushes punches over **plain HTTP** using the ZKTeco/ESSL
ADMS protocol (fixed `/iclock/*` paths). This Cloudflare Worker is the
endpoint the device points at; it forwards each punch to the
`adms_ingest()` RPC in Supabase (see
`dashboard/schema/2026-08-essl-adms.sql`), which applies the exact same
attendance rules as the tablet kiosk.

## Deploy (one time)

1. Create a free Cloudflare account. When asked to pick a
   **workers.dev subdomain**, choose something short, e.g. `seematti`
   → the bridge URL becomes `adms.seematti.workers.dev`.
2. From this folder:

   ```
   npx wrangler login
   npx wrangler deploy
   npx wrangler secret put SUPABASE_URL       # https://<ref>.supabase.co
   npx wrangler secret put SUPABASE_ANON_KEY  # project anon key
   npx wrangler secret put ADMS_SECRET        # value of settings.adms_secret
   ```

3. Verify: `curl http://adms.<subdomain>.workers.dev/iclock/getrequest?SN=test`
   → prints `OK` (over plain http — that is the point).

## Point the device at it

On the uFace302: **Menu → Comm. → Cloud Server Setting**
- Server Mode: `ADMS`
- Enable Domain Name: `ON`
- Server Address: `adms.<subdomain>.workers.dev`
- Enable Proxy Server: `OFF`

Then restart the device. Its serial number appears in `adms_devices`
within a minute (heartbeat), and every punch lands in `adms_punches`
with its outcome.

## Notes

- The device buffers punches offline (100k logs) and re-sends until
  acknowledged; `adms_ingest` is replay-proof (unique on
  sn + user + timestamp), so retries are safe.
- Punch → check-in/check-out is decided server-side by shift state,
  not by which status key staff press.
- To block a lost/rogue device, set `enabled=false` on its
  `adms_devices` row.
