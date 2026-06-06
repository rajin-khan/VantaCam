# Vercel Static Dashboard

Deploy this directory as its own Vercel project root.

## Required Environment Variable

Set this in Vercel:

```text
PI_API_BASE=https://raspberrypi.your-tailnet.ts.net
```

Use the Tailscale Serve HTTPS URL for the Pi dashboard backend. Do not include a
trailing slash.

## What Vercel Hosts

Vercel hosts:

- `index.html`
- `assets/styles.css`
- `assets/app.js`
- `/api/config.js`

`/api/config.js` exposes only `PI_API_BASE` to the browser. It does not contain
passwords, password hashes, stream paths, sudo rules, or session secrets.

## Runtime Flow

1. Your phone loads this dashboard from Vercel.
2. The browser requests `/api/config.js`.
3. The browser calls the Pi API directly at `PI_API_BASE`.
4. The Pi accepts the browser calls only when `CORS_ORIGIN` matches the Vercel
   URL and the request carries a valid login cookie.

The phone must be connected to Tailscale. This is not a public camera gateway.

## Local Preview

From the repo root, run the backend:

```bash
node web/server.js
```

Then run this folder's preview server:

```bash
cd vercel-site
PI_API_BASE=http://127.0.0.1:3100 node local-preview.js
```

Open:

```text
http://127.0.0.1:3000/
```

Use the dashboard login password from the ignored private runbook:

```text
../CAMERA-RUNBOOK.md
```

The local preview server proxies `/api/*` and `/stream/*` to `PI_API_BASE`, so
the browser keeps its login cookie on the same `localhost:3000` origin.
