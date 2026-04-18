# Seemaatti Admin

Mobile admin app prototype for **Seemaatti** — a 3-floor, 300+ employee saree retail showroom in Mayiladuthurai.

Covers HR, daily operations, and management workflows across three roles:

- **Owner** — dashboard, section status, leave approvals, attendance overview, tasks, announcements, visitors
- **HR** — HR home, manual attendance, attendance kiosk (face-scan flow), joiner enrollment
- **Staff** — personal home, apply leave, payslip

## Running

Open `index.html` in a modern browser, or serve the folder over HTTP:

```
python3 -m http.server 8000
```

Then visit http://localhost:8000/.

Requires internet access on first load (React, ReactDOM, and Babel Standalone are pulled from unpkg).

## Screens

Owner flow — Login → Owner Home → Attendance → Leaves → Tasks → Announcements → Visitors
HR flow — HR Home → Mark Attendance → Kiosk Scanner → Enroll Joiner
Employee flow — Staff Home → Apply Leave → Payslip

The left side picker jumps between screens. The bottom-right **Tweaks** panel toggles English ⇄ தமிழ், card density, and dashboard layout.

## Structure

- `index.html` — complete prototype (React via Babel Standalone, all components inlined)
- `assets/seemaatti-logo.png` — brand lockup (also inlined as a data URI in `index.html`)
