# Admin app update plan — the machine takes attendance, Quanto creates staff, the app does reports and HR work

**Owner decision, 25 Sep 2026:** stop the tablet face-kiosk and face enrolment in the admin app. The eSSL machine takes attendance. Quanto is the only place a staff member is created; the app and the machine pick them up automatically. The app becomes the place for reports, leave, advances, payroll and the small daily HR work.

Repo: `Seematti-admin` (phone app = root `index.html`, desktop console = `dashboard/`; one merge to `main` deploys both). Database: Supabase `hixhbznbejqfnasvgyid`. Machine bridge: `adms-bridge/` + M1 crons `seematti-staff-sync`, `seematti-adms-watch`.

## 1. Where we stand today (25 Sep, end of day)
| | Count |
|---|---|
| Staff in the app | 165 (146 have a tablet face, 132 have an SA/SS code) |
| Coded staff present on the machine as a user | 132 of 132 |
| Coded staff who have actually punched the machine in 30 days (= face/finger enrolled there) | **89 of 132** |
| Staff with no code yet (HR list in the audit doc §8) | 33 |
| Attendance events last 30 days | tablet: 2,649 in · 2,167 out · **138 outpass-out · 96 outpass-in** — machine: 0 (gate opens 26 Sep 08:00) |
| Tablets alive | 1 (`kiosk-cvldh6zj`) |
| Machine status keys used by staff | never (every punch is status 0) |

Two facts shape the plan: **43 coded staff have never touched the machine**, and **outpasses (234 a month) exist only on the tablet** — the machine cannot record them unless staff press its Break-Out/In keys.

## 2. Target picture
```
Quanto (HR creates the salesman, SA/SS code)
   └─ seematti-staff-sync (M1, every 30 min) ──▶ app `employees` (id, name, code, section, company)
                                                     └─ trigger ──▶ eSSL machine user record ──▶ HR enrols face/finger AT the machine
Machine punch ──▶ adms_ingest ──▶ `attendance` + `attendance_events` (present/late, in/out, shift day, Sunday rule)
App = reports · leave · advances · payroll · tasks · announcements · visitors · holidays · employee details (salary, bank, phone)
```
The tablet, the face photos, the kiosk PIN and the kiosk heartbeat all go.

## 3. What retires (the complete list)
| Piece | Where | Action |
|---|---|---|
| Kiosk screen (face scan, in/out/outpass buttons) | phone app `kiosk` screen; desktop `Kiosk & face` settings page | remove screens + nav entries |
| Face enrolment (3 photos on hire) | phone app `enroll` flow | remove; "Add employee" is replaced (§4.2) |
| `face_embeddings` table + `face_all` policy | DB | export once to a private backup, then drop (face vectors are personal data; nothing else reads them) |
| Kiosk RPCs `kiosk_scan`, `kiosk_match`, `kiosk_punch`, `kiosk_meta`, `kiosk_heartbeat` | DB | drop after cutover |
| `kiosk_event` + `kiosk_emp_state` | DB | **keep, renamed** — they become the app's manual attendance/outpass path (§4.4) |
| `kiosk_pin` setting; `kiosk_heartbeats` table; dead-kiosk alert + nightly self-refresh (#56) | DB / app | drop |
| The tablet | hardware | keep as a cold standby for one season (it can still run the old kiosk if the machine dies), then repurpose |
| Kiosk-era docs and CLAUDE.md lines | repos | rewrite |

Nothing else in the app depends on the kiosk: reports, leave, advances, payroll and email automations read `attendance`, and the machine writes the same rows.

## 4. What changes in the app
### 4.1 Employee directory (both surfaces)
- **Employee Code is the identity.** Required for every staff row, SA/SS format checked, editable on the phone as well as the desktop, unique (already enforced in the DB). Hint text "SA455", not "E001".
- **No "New employee" for salesmen.** Staff arrive from Quanto. The add button becomes "Add non-Quanto staff" (security, driver, office, owner) and asks for the code. If a name typed there matches a Quanto arrival, the app says so.
- **Delete is gone.** Deactivate is the only leaver action (a deleted person is recreated by the sync with a new id and no history). Owner-only if kept at all.
- **"From Quanto — details pending" flag** on rows the sync created: salary, phone, bank, ESI/PF still blank. HR completes them from the directory.
- Show per person: code · on machine ✓ · enrolled (has punched) ✓ · Quanto id · probable-match flag to confirm.

### 4.2 Machine page (new, desktop + phone read-only)
Device last-seen and go-live switch · staff without a code · coded but never punched (not enrolled) · unknown machine IDs punching · PIN conflicts (`adms_pin_conflicts`) · codes duplicated in Quanto · the sync's PROBABLE matches to confirm/reject · today's punches per person. Everything is already in the database (`adms_*`, `staff_sync_state`); this is one screen.

### 4.3 Attendance reports
- Source column/badge: machine · manual · leave. (The kiosk source disappears after cutover; history keeps it.)
- Daily report unchanged otherwise: present/late/absent/on-leave, early leavers, in/out times.
- Email automations unchanged (they read `attendance`).

### 4.4 Outpass and corrections
The machine only knows in/out. Two ways to keep outpasses; pick one (owner decision D1):
- **A. Machine keys.** Staff press the machine's Break-Out / Break-In key before scanning; `adms_ingest` maps status 4/5 to `outpass_out`/`outpass_in`. Zero app work for staff, but a habit to teach, and a forgotten key press turns an outpass into a check-out.
- **B. In the app.** A supervisor (or the staff member on the phone) records "went out 12:10 / back 12:40". Reuses today's `kiosk_event` logic under a new name `attendance_mark`. Reliable, one more tap for a supervisor.
Recommendation: **B now, A later if the habit forms.** Same screen also does the manual corrections HR does today (missed punch, wrong day).

### 4.5 Leave, advances, payroll, tasks, announcements, visitors, holidays
Unchanged. They already work from `attendance` and `employees`. The open HR decisions from 1 Aug (absent-pay policy, EMI timing, coverage caps, who fills salaries) are unaffected by this plan and still open.

## 5. Back-end changes
| Change | Note |
|---|---|
| `adms_ingest` becomes the only automatic writer of attendance | the cross-source guard stays (manual entries still count as events) |
| Status-key mapping (only if D1 = A) | `p_status` 4/5 → outpass events |
| `attendance_mark(employee, action, time)` | today's `kiosk_event` without the PIN and without the tablet; role-guarded to hr/manager/owner |
| Sync (`quanto_staff_sync.mjs`) | add `code_source` ('hr' / 'quanto' / 'quanto_probable') so the Machine page can list matches to confirm; keep leavers report-only |
| Watchdog (`seematti-adms-watch`) | already live: silent machine >20 min, live rail writing nothing by 11:00 |
| Second machine (owner decision D3) | one device is a single point of failure for 165 salaries; a second uFace302 at the other entrance registers itself (`adms_devices`) with no code change |

## 6. Cutover — phased, each phase has a gate
**Phase 0 — now to 26 Sep 08:00.** Machine starts writing attendance beside the tablet. Nothing retires. Watchdog live.

**Phase 1 — 26 Sep to ~5 Oct (enrolment + app build).**
- HR: enrol every coded person on the machine (43 to go), type the 33 missing codes, fix the 11 duplicated codes in Quanto, confirm the 7 probable matches.
- Build: §4.1 directory rules, §4.2 Machine page, §4.4 `attendance_mark` (option B), source badges. Deploy behind the existing nav; the kiosk keeps running.
- Daily gate reading on the Machine page: *coded-but-never-punched* → 0; *tablet-only check-ins per day* → 0.
- Gate to Phase 2: **every active staff member has punched the machine on 5 consecutive working days, and tablet-only check-ins have been 0 for 3 days.**

**Phase 2 — cutover day (a Monday, 08:00).** Tablet shows "Use the machine" and stops taking scans (one line in the app config; instantly reversible). Machine is the only source. Outpasses via §4.4. Watch the first payroll day-count against the previous month.
- If the gate is not met by 6 Oct: **run both through Diwali (9 Oct–8 Nov) and cut over the week after.** The guard already makes dual-running safe; a season is the wrong time to change how 165 people clock in. (Owner decision D2.)

**Phase 3 — two weeks after cutover.** Drop the kiosk screens, RPCs, `kiosk_pin`, `kiosk_heartbeats`, the #56 alert; export `face_embeddings` to a private backup and drop the table; rewrite docs and CLAUDE.md; tablet to standby.

## 7. Rules for HR from now on
1. A new person is created **in Quanto** with a fresh SA/SS code. Never reuse a code. The app and the machine follow within 30 minutes.
2. Then enrol the face/finger **at the machine** under that code.
3. Fill salary, phone and bank **in the app** (desktop console).
4. A leaver is **deactivated in the app**. Never deleted.
5. Outpass and corrections are recorded in the app (§4.4).
6. Anything odd shows on the Machine page first; look there before asking.

## 8. Owner decisions needed
| # | Decision | Recommendation |
|---|---|---|
| D1 | Outpass: machine keys (A) or in the app (B) | B now |
| D2 | Cut over before Diwali only if the gate is met by 6 Oct; otherwise after 8 Nov | agree |
| D3 | Second machine as backup | yes, before Diwali |
| D4 | Non-salesman staff (security, drivers, office): created in Quanto with an SA/SS code too, or added in the app | Quanto, so there is one rule |
| D5 | Delete rights | nobody |
| D6 | Keep the tablet as standby for one season | yes |

## 9. Effort
Phase 1 app work ≈ 3 builder-days (directory rules 1, Machine page 1, attendance_mark + badges 1), all inside `Seematti-admin`. Phase 3 clean-up ≈ half a day. HR enrolment is the long pole, not the code.

---

## 10. Decisions taken 25 Sep evening, and what was built the same night

| # | Decision | Built |
|---|---|---|
| D1 | **Outpass from the machine.** | `adms_ingest` now reads the status key: **Break-Out (status 2) = going out on outpass; Break-In (3) or any scan while on outpass = back.** First scan of the shift is always the check-in whatever key was pressed; a scan within 30 min of arrival is ignored; otherwise the last scan is the check-out. HR corrections (missed punch, forgotten key) via `attendance_mark` in the app, source = manual, with who marked it. |
| D2 | Before Diwali only if the gate is met by 6 Oct | unchanged |
| D3 | Second machine: **same model, eSSL uFace302** (or eSSL's current successor in the same ADMS family if 302 is out of stock) at the second entrance. It registers itself the moment it is pointed at `adms.adms-bridge.workers.dev`; no code change. Faces must be enrolled on each machine until template copying is built. | procedure in §11 |
| D4 | Everyone — salesmen, security, drivers, office — is created **in Quanto** with an SA/SS code. The app's "Add staff" is kept only as an emergency door and asks for the code. | sync + app |
| D5 | Delete = **owner only** | DB policy `emp_delete` |
| D6 | **Tablet decommissioned.** | Setting `kiosk_enabled`; the tablet's scan function refuses when it is `false`. ⚠️ See §12 before switching it off. |

Also built tonight (DB, live): `attendance_apply` (one writer for machine and manual events), `attendance_timing_report` and `attendance_summary_report` (the 1M/6M staff-wise reports), views `v_machine_staff` and `v_machine_unknown_pins`, table `quanto_code_conflicts` (the M1 sync fills it: 11 codes today), `employees.code_source`. App surfaces: see §13 once the builders land.

## 11. Machine setup for outpass (do this once on the uFace302; menu names as on the ZKTeco firmware 8.0.4.6)
1. **Menu → Personalize → Punch State Options.** Set **Punch State Mode = Manual Mode** (staff choose a state before scanning; the device reverts to the default after the timeout). Set **Punch State Timeout** to 5–10 s and leave **Punch State Required** off (a plain scan still counts as in/out).
2. **Menu → Personalize → Shortcut Key Mappings** (or the on-screen state buttons on the standby page): keep **Check-In**, **Check-Out**, **Break-Out**, **Break-In**. Hide Overtime-In/Out to avoid wrong taps.
3. Verify the codes on the first live outpass: the punch must arrive with `status_code = 2` (Break-Out) and `3` (Break-In) in `adms_punches`. If the firmware uses different numbers, change the two constants in `adms_ingest` (the mapping is in one place). 
4. Teach the habit: **going out on outpass = tap Break-Out then scan; coming back = scan (Break-In optional).** Leaving for the day = just scan.
5. Duplicate-punch window on the device (Menu → System → Attendance → Duplicate Punch Period) should stay at 1 minute; our own 2-minute guard is on top.

## 12. ⚠️ The tablet switch-off gate (D6)
Tonight 76 of 165 staff are not usable on the machine: 33 have no code and 43 are on the machine without a face. If the tablet is switched off tomorrow, those 76 are absent in every report until enrolled. The switch is ready (`kiosk_enabled`); the recommendation is: HR enrols at the machine in batches over the next days, the Machine page shows the two lists shrinking, and the tablet is switched off the morning the lists read zero — then physically removed. The machine's own faults (the 30-min clock, unknown IDs) are now visible, so the tablet is not needed as a monitor.

## 13. Reports the HR department gets (Reports & exports page)
| Report | Range | What it answers |
|---|---|---|
| **Staff attendance & timing** (new) | this month · last month · 3 months · 6 months · custom; all staff or one person; by section | per person per day: in, out, late minutes, left early, outpasses and minutes, hours inside, source (machine/tablet/manual), who corrected it. CSV and XLSX. |
| **Attendance summary per staff** (new) | same presets | one row per person: days, present, late, leave, absent, holidays, total late minutes, early leaves, outpasses, average in/out, hours inside, days with no check-out. CSV and XLSX. |
| **Machine punch log** (new) | date range, optional person | every raw punch the machine sent, for disputes |
| Attendance export | any range | the daily rows as before, source printed as Machine |
| Payroll export · Leaves export · Employee directory | as before | unchanged |
| Daily report · Previous-day report (email, 11:00 / 11:30) | daily | unchanged, now fed by the machine |

Follow-ups worth adding later: a monthly PDF per section for supervisors, and the timing report as an email automation on the 1st of each month.
