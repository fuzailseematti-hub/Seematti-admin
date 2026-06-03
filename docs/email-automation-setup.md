# Email automations — setup

Scheduled report emails (dashboard → **Account → Email automations**). A
`pg_cron` job runs every 15 minutes and calls the `run-automations` edge
function, which builds the requested report from the DB and sends it via
**Resend**. Two report types: `daily_attendance` (today's present/late/absent,
section-wise) and `next_day_leave` (who's on leave tomorrow, section-wise).

Everything is already deployed **except the email key**. To make emails
actually send, do this one-time setup:

## 1. Create a Resend account + API key
1. Sign up at https://resend.com.
2. **API Keys → Create API Key** (Sending access). Copy it (`re_...`).

## 2. Verify the seematti.app domain (so mail is from reports@seematti.app)
1. Resend → **Domains → Add Domain** → `seematti.app`.
2. Resend shows DNS records (SPF / DKIM, usually a few `TXT` and `MX`/`CNAME`).
3. Add those records in **Vercel → your domain (seematti.app) → DNS**.
4. Back in Resend, click **Verify** (can take a few minutes to propagate).
   - Until verified you can change the `FROM` in the function to Resend's test
     sender (`onboarding@resend.dev`) to try it out, but real sending needs the
     domain verified.

## 3. Give the key to the edge function
Supabase dashboard → **Edge Functions → Secrets** (or Project Settings →
Functions → Secrets) → add:

```
RESEND_API_KEY = re_xxxxxxxxxxxxxxxxxxxx
```

That's it. The function reads `RESEND_API_KEY` from the environment; no redeploy
needed. The next scheduled run (or any automation whose send-time has passed
today) will email.

## How sending works / dedupe
- The cron runs every 15 min. An automation fires once per day, at the first run
  at/after its `send_time` (IST). `last_sent_on` prevents resends the same day.
- `daily_attendance` reports **today**; `next_day_leave` reports **tomorrow**.
- Recipients, time, and on/off are all editable on the Automations page.

## Pieces (for reference)
- Table `public.automations`, private `public.app_config` (holds the internal
  cron secret — RLS-locked, only the service role reads it).
- Edge function `run-automations` (`supabase/functions/run-automations/index.ts`),
  gated by the `x-cron-secret` header.
- `pg_cron` job `run-automations` (`*/15 * * * *`) → `pg_net` → the function.
- Migration: `dashboard/schema/2026-06-automations.sql`.
