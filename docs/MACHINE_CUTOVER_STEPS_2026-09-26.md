# The 9 steps to finish the move to the attendance machine — in detail

Written 26 Sep 2026 for the owner and HR. Simple words. Each step says **who**, **where**, **exactly what to do**, and **how you know it worked**.

**The three places you will use**
| Place | Link / location | Login |
|---|---|---|
| Desktop console ("the website") | https://seematti-admin-dashboard.vercel.app | your usual console login (owner, admin, HR) |
| Phone app | https://seematti-admin.vercel.app (or the icon on the phone) | same login |
| The machine | eSSL uFace302 at the showroom entrance, serial BRM9213360068 | its admin menu (the admin user set on the device) |

Reference documents (for whoever wants the why): `docs/ADMIN_APP_UPDATE_PLAN_2026-09-25.md` (the plan) and `docs/ESSL_BIOMETRIC_AUDIT_2026-09-25.md` (the audit) in the seematti-intelligence repo. Machine manual: ZKTeco/eSSL uFace series user manual — https://www.manualslib.com/manual/1841966/Zkteco-Uface-Plus-Series.html (same firmware family) and the eSSL product page https://esslsecurity.com/face/uface302.

---

## Step 1 — Set the machine to accept outpass taps (owner or HR, 5 minutes, once)

**Why:** the machine only knows "scan". To record an outpass it must let staff say "I am going out for a while" before they scan. That is the Break-Out key.

**Where:** on the machine itself. Press **M/OK** (or the menu icon on the screen) and log in as admin.

**Do:**
1. **Menu → Personalize → Punch State Options.**
2. **Punch State Mode → Manual Mode.** (Meaning: staff choose a state by tapping a key before scanning. A plain scan without a key still works and counts as normal in/out.)
3. **Punch State Timeout → 10 seconds.** (After 10 seconds the chosen key resets, so nobody is stuck on the wrong state.)
4. **Punch State Required → Off.**
5. Go back. **Menu → Personalize → Shortcut Key Mappings.** Make sure these four exist and are visible on the standby screen: **Check-In, Check-Out, Break-Out, Break-In.** If Overtime-In / Overtime-Out are shown, set those keys to "Undefined" so nobody taps them by mistake.
6. Also check **Menu → System → Attendance → Duplicate Punch Period = 1 minute** (leave as is if it already says 1).

**Then test it (this is the important part):** ask one staff member (whose code is already linked, for example anyone from the Silk section) to do this at any time today:
- Tap **Break-Out** on the screen, then scan the face. Wait one minute.
- Scan the face again (no key).
Then send me one line: "outpass test done, <name>, <time>". I will read the two punches the machine sent and confirm the codes are what the app expects. If the numbers differ, I change one line on my side; nothing changes for staff.

**How you know it worked:** on the console → **Attendance** → that person's row shows an outpass badge, and **Reports → Staff attendance & timing** shows 1 outpass for today.

**Menu names may differ by one word on your firmware** (it is version 8.0.4.6). If you cannot find "Punch State Options", look under **Personalize** or **System → Attendance**. Photograph the screen and send it to me if stuck.

---

## Step 2 — Give the 33 people their SA/SS code (HR, about 30 minutes)

**Why:** the machine knows a person only by the SA/SS code. Without a code the person cannot get attendance from the machine.

**Where:** console → left menu → **Operations → Attendance machine** → the table **"No code"**.

**Do, for each name in that table:**
1. Find the person in **Quanto → Employee master** (the same place you create salesmen). Note the code (like SA455 or SS272).
2. In the console → **People → Employees** → click the person → **Employee code** box → type the code → Save.
3. The row disappears from "No code" and, within a minute, appears under "Not enrolled yet" (the machine now has the person's record, waiting for a face).

**Rules:**
- The code must be exactly the Quanto code. Capitals do not matter; the app fixes them.
- If the console says **"This code already belongs to another employee"**, that code is in use — check Quanto; usually it is a duplicated code (see Step 4) or the same person entered twice in the app. Do not force it.
- If the person is not in Quanto at all (a security guard, a driver): create them in Quanto first with a new code, then come back. Everyone gets a code in Quanto, no exceptions (owner's rule).

**How you know it worked:** "No code" reads **0**.

---

## Step 3 — Enrol faces at the machine (HR at the machine, 2–3 minutes per person)

**Why:** the machine has a record for each coded person, but it recognises nobody until the face (or finger) is enrolled under that code.

**Where:** console → **Attendance machine** → table **"On machine, not enrolled yet"**. Print it or keep it open on the phone app (**Tools → Attendance machine**).

**Do, at the machine, per person:**
1. **Menu → User Mgt. → All Users** → search the code (for example type SA514) → open.
2. Choose **Face** → follow the on-screen frame: look straight, then slightly up/down as it asks. Green tick = done.
3. Optional but good: also **Fingerprint** → one finger, three presses. A finger works when a mask or glasses confuse the camera.
4. Tell the person to scan once now, so it counts as today's check-in and proves the enrolment.

**Rules:**
- Enrol under the **code**, never a new ID. If you cannot find the code on the machine, the person is still in "No code" (Step 2) — do that first.
- If the machine already shows the person under an **old ID** (for example SA455 B.ABINASH) and they scan fine, leave them; they are already linked. Only the ones listed in "not enrolled yet" need work.
- Do batches: 10–15 people a day, before 09:00 or after 20:00 when the entrance is quiet.

**How you know it worked:** the person leaves the "not enrolled yet" table after their first scan; their name shows on **Attendance machine → Today's punches**.

---

## Step 4 — Fix the 11 duplicated codes in Quanto (HR in Quanto, 20 minutes)

**Why:** Quanto lets two active people carry the same code. On the machine one code = one face, so a duplicated code would make one person's scan count for the other. The app refuses to push a duplicated code, so these people are stuck until Quanto is fixed.

**Where:** console → **Attendance machine** → table **"Codes duplicated in Quanto"**. It lists the code and both names.

**Do, for each code:**
1. Open **Quanto → Employee master** → search the code → you will see two (sometimes three) people.
2. The person who **left** → mark them **inactive** in Quanto (or change their code to something like X-old). The person still working keeps the code.
3. If **both** still work (SA407 = N.NAFEES and M.AJAY; SS27 = PUSHKAR SINGH and SHAJAHAN): give the newer person a **fresh, unused** code.
4. Within 30 minutes the app picks up the change; the code leaves the table.

**Rules:** never reuse a code from a leaver for a new person. New person = new code, always.

**How you know it worked:** the table is empty. Start with SA407 and SS27 — both have an app employee waiting on them.

---

## Step 5 — Confirm the 7 "probable" matches (HR, 5 minutes)

**Why:** for seven people the app matched the Quanto name to the app name by a near spelling (for example RAJESH in Quanto and RAJESH.M in the app). A human must say yes or no.

**Where:** console → **People → Employees** → rows with the yellow badge **"PROBABLE match — confirm"**. Also listed on **Attendance machine → Probable matches**.

**Do:** for each badge, look at the name and the code. If it is the same person → **Confirm**. If not → **Wrong code**, then type the right code in the Employee code box (Step 2).

The seven: N.SIVASUBRAMANIYAM (SA503) · K.SEENIVASAN (SA498) · A.PRAVEENKUMAR (SA506) · RAJESH.M (SA508) · PRAVEEN. S (SA513) · R.MANIKANDAN (SA515) · G.SUNDARRAJ (SS452).

**How you know it worked:** no yellow badges left.

---

## Step 6 — Switch the tablet off, then remove it (owner, 1 minute — but only at the right moment)

**Why:** the owner's decision is to decommission the tablet. But today 76 people are not usable on the machine yet (33 without a code, 43 without a face). If the tablet goes off before Steps 2–3 are finished, those people show **absent** in every report.

**When:** the morning **Attendance machine** shows **"No code" = 0** and **"On machine, not enrolled yet" = 0**.

**Where:** console → **Account → Settings** → card **"Attendance machine"** → toggle **"Tablet kiosk accepts scans"** → OFF → confirm.

**What happens:** the tablet keeps showing its screen but every scan is refused with "Tablet is switched off — use the attendance machine". Nothing is deleted. To reverse: same toggle → ON.

**Then:** unplug the tablet and put it away. After two weeks of clean machine attendance I remove the tablet code and the old face photos from the system (Phase 3 in the plan).

---

## Step 7 — Buy the second machine (owner)

**What:** one more **eSSL uFace302** (same model as the current one). If the supplier says 302 is discontinued, ask for eSSL's current successor in the same "uFace / ADMS push" family and send me the model name before buying.

**Why the same model:** same menus for HR, same behaviour, and it joins our system with zero code change.

**Where to put it:** the second entrance (or the first floor), so a queue never forms at one machine and one broken machine never stops attendance for 165 salaries.

**Setup when it arrives (10 minutes, I can guide on the phone):**
1. Connect it to the store Wi-Fi / LAN.
2. **Menu → Comm. → Cloud Server Setting**: Server Mode = ADMS · Enable Domain Name = ON · Server Address = **adms.adms-bridge.workers.dev** · Port 80 · Proxy OFF. Restart.
3. It appears on **Attendance machine** within a minute. I name it and it is live.
4. HR enrols faces on it as in Step 3. (Until template copying is built, each person is enrolled on each machine. Most people will use one entrance; enrol them where they walk in.)

**Supplier links:** eSSL product page https://esslsecurity.com/face/uface302 · typical Indian resellers list it under "eSSL uFace 302 face + finger attendance machine" (₹15,000–20,000 range).

---

## Step 8 — Tell the staff (a two-line notice at the machine, in Tamil and English)

**Arriving:** scan your face. **Leaving for the day:** scan your face.
**Going out on outpass:** tap **Break-Out** on the screen, then scan. **Coming back:** just scan.

That is all. Two extra rules for the notice board:
- Scan once. A second scan within 30 minutes of arriving is ignored, so nobody can "check out" by mistake in the morning.
- Missed a scan? Tell your supervisor the same day; they fix it in the app (Step 9).

---

## Step 9 — Tell HR the standing rules (print and keep at the HR desk)

1. **New staff are created in Quanto, with a new SA/SS code.** Never in the app first. The app and the machine follow within 30 minutes. Then enrol the face at the machine (Step 3).
2. **Never reuse a code.** A leaver's code dies with them.
3. **Leavers are deactivated in the app** (Employees → Deactivate). **Never deleted** — delete wipes their attendance, leave and payslips, and the app would recreate them anyway. Only the owner can delete.
4. **Missed punches and forgotten outpass taps are fixed in the app:** console → Attendance → **"Mark punch / outpass"**, or phone app → Tools → **Mark punch / outpass**. Choose the person, the action, the time, save. The report shows who made the correction.
5. **Reports:** console → **Insights → Reports & exports** → **Staff attendance & timing** (per person per day, 1 or 6 months, Excel) and **Attendance summary per staff** (one line per person). Both come from the machine.
6. **If something looks wrong, look at Attendance machine first** — device last seen, unknown IDs, conflicts. The owner also gets a Telegram message if the machine goes silent for 20 minutes during store hours.

---

**Order matters:** 1 → 2 → 3 → (4 and 5 alongside) → 6 last. Step 7 whenever the machine arrives. Steps 8–9 today.
