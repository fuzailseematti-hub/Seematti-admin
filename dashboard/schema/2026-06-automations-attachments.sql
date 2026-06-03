-- Per-automation attachment format. APPLIED to prod 2026-06-03.
-- The run-automations edge function attaches a printable PDF and/or a CSV to the
-- report email based on this column (none | pdf | csv | both). PDF/CSV are built
-- in the function (pdf-lib) from the same report model as the email body, with
-- the Seemaatti logo in the header.
alter table public.automations
  add column if not exists attach_format text not null default 'pdf'
  check (attach_format in ('none','pdf','csv','both'));
