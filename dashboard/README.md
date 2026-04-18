# Seemaatti Admin Dashboard

Desktop admin console for the Seemaatti app. Controls everything in the
Supabase backend — employees, sections, attendance, leaves, tasks,
announcements, visitors, payslips, reports.

Shares the same Supabase project as the mobile app.

## Running locally

Static HTML — just serve the folder:

```
python3 -m http.server 8080 --directory dashboard
```

Then visit http://localhost:8080/.

## Deploying (separate Vercel project)

This folder is designed to ship as its own Vercel deployment so the
mobile app and the admin dashboard have independent URLs.

1. Go to https://vercel.com/new
2. Import `fuzailseematti-hub/Seematti-admin`
3. Name the project **seematti-admin-dashboard**
4. Framework preset: **Other**
5. **Root directory**: `dashboard`
6. Build command: *(none)*
7. Output directory: `.`
8. Deploy

You'll get a URL like `seematti-admin-dashboard.vercel.app`.

## Password

The dashboard is gated by a single shared password. The **default is**:

```
Seemaatti@2026
```

To change it, compute the SHA-256 of your new password and replace
`window.ADMIN_PASSWORD_SHA256` at the top of `index.html`:

```bash
printf '%s' 'YourNewPassword' | sha256sum
```

## Roles

After unlocking, the dashboard has a role switcher in the sidebar:

- **Owner** — full access.
- **HR** — restricted: cannot edit sections, cannot edit payslips,
  cannot delete employees. Everything else works.
