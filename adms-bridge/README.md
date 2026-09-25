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

## Since 25 Sep 2026: the admin app is the master list

- Every employee's machine PIN is their **SA/SS salesman code**
  (`employees.employee_code`, the Quanto code, UNIQUE). `adms_users` is
  filled automatically (`adms_sync_employee`, trigger `adms_employee_sync`);
  nothing is mapped by hand. Staff are born in Quanto: the M1 cron
  `seematti-staff-sync` creates/links app employees from Quanto's
  `employee` table, and this trigger pushes them here.
- Quanto REUSES codes. The app keys on `quanto_employee_id`, keeps
  `adms_roster` (what the machine holds) and refuses to push a PIN the
  machine already holds under another name (`adms_pin_conflicts`).
- Every employee is pushed to the device as a user record through
  `adms_commands` (`DATA UPDATE USERINFO`). Faces and fingers are still
  enrolled AT the machine, under that PIN.
- `TimeZone=330` in the handshake (MINUTES: the protocol reads |x|<12 as
  hours, anything larger as minutes). `5.5` was read as 5 and ran the
  device 30 minutes slow for seven weeks. The clock is only re-synced on
  the boot handshake — after changing it, queue `REBOOT`, not
  `RELOAD OPTIONS`.
- A punch within 30 min of a recorded check-in (tablet or machine) is the
  same arrival, never a check-out — enforced in `adms_ingest` and
  `kiosk_event`.
- Switch: `settings.adms_go_live_at` (`2099-01-01 00:00:00` = off).
- Redeploy: `npx wrangler login` (opens an OAuth page — approve it in the
  owner's Chrome), then `npx wrangler deploy`. Secrets survive redeploys.
- Schema: `dashboard/schema/2026-09-essl-app-primary.sql`.
