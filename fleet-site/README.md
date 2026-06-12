# VantaCam Fleet Site

This is the multi-camera Vercel dashboard.

Use this folder when you want one phone-friendly page that can show multiple
tailnet camera hosts.

## How It Works

The fleet page is static HTML, CSS, and JavaScript. It loads camera host URLs
from:

```text
/api/config.js
```

On Vercel, that function reads:

```text
FLEET_CAMERAS_JSON
```

The browser then talks directly to each camera host API. Because the Vercel page
is HTTPS, each camera API should also be HTTPS through private Tailscale Serve
or the Mac Tailscale certificate proxy fallback. Do not use Tailscale Funnel.

If a camera host has rewind enabled, `/api/status` includes a `rewind` object.
The dashboard uses that to show the `Replay` action for the current or most
recent bounded buffer.

Replay playback is HLS. Safari and iPhone browsers can usually play HLS
natively. Chrome, Arc, and many Chromium desktop browsers need MediaSource
support through hls.js, so this folder vendors a pinned local copy:

```text
vendor/hls.min.js
vendor/hls.LICENSE.txt
```

The dashboard loads that local file before `assets/app.js`. Do not replace it
with a CDN script; keeping it local avoids a runtime third-party dependency on a
private camera dashboard.

## Camera Config

Use `cameras.example.json` as the shape:

```json
[
  {
    "id": "pi-main",
    "name": "Raspberry Pi",
    "kind": "USB webcam",
    "apiBase": "https://raspberrypi.your-tailnet.ts.net",
    "streamUrl": "https://raspberrypi.your-tailnet.ts.net:8443/cam-your-private-path/"
  },
  {
    "id": "macbook",
    "name": "MacBook Pro",
    "kind": "Built-in or USB camera",
    "apiBase": "https://macbook.your-tailnet.ts.net:9443",
    "streamUrl": "https://macbook.your-tailnet.ts.net:9444/mac-your-private-path/"
  }
]
```

Fields:

- `id`: stable local UI id.
- `name`: display name.
- `kind`: small label above the camera name.
- `apiBase`: camera dashboard API origin.
- `streamUrl`: optional WebRTC URL override. If omitted, the dashboard uses the
  `webrtcUrl` returned by `/api/status`.

Check the config before running or deploying:

```bash
node fleet-site/verify-config.js --file fleet-site/cameras.example.json
```

For Vercel/production values, require HTTPS:

```bash
FLEET_CAMERAS_JSON='[...]' node fleet-site/verify-config.js --production
```

## Local Preview

Create an ignored local config:

```bash
cp fleet-site/cameras.example.json fleet-site/cameras.local.json
```

Edit `fleet-site/cameras.local.json`, then run:

```bash
cd fleet-site
node verify-config.js
node local-preview.js
```

Open:

```text
http://127.0.0.1:3300/
```

In local preview, the server proxies camera API calls through its own origin:

```text
Browser -> http://127.0.0.1:3300/camera/<id>/api/status -> camera host
```

That lets you test login, status, and on/off controls against direct tailnet HTTP
hosts without fighting browser cross-site cookie rules. The iframe stream URL is
still loaded from the camera host itself.

The preview proxy waits up to 30 seconds for camera API responses because
starting MediaMTX and ffmpeg can take a little while on older machines. Override
that if needed:

```bash
CAMERA_PROXY_TIMEOUT_MS=45000 node local-preview.js
```

For production Vercel, the browser talks directly to camera host APIs, so each
camera host must allow the deployed Vercel origin in its CORS config.

## Vercel Deployment

Deploy this folder:

```text
fleet-site
```

Set exactly one Vercel environment variable for the fleet dashboard:

```text
FLEET_CAMERAS_JSON=[{"id":"pi-main","name":"Raspberry Pi","kind":"USB webcam","apiBase":"https://raspberrypi.your-tailnet.ts.net","streamUrl":"https://raspberrypi.your-tailnet.ts.net:8443/cam-your-private-path/"},{"id":"macbook","name":"MacBook Pro","kind":"Built-in camera","apiBase":"https://macbook.your-tailnet.ts.net:9443","streamUrl":"https://macbook.your-tailnet.ts.net:9444/mac-your-private-path/"}]
```

Use `.env.example` as the public-safe template. Put the real private value in
Vercel, not in Git.

Validate the same value before saving it in Vercel:

```bash
FLEET_CAMERAS_JSON='[{"id":"pi-main","name":"Raspberry Pi","kind":"USB webcam","apiBase":"https://raspberrypi.your-tailnet.ts.net","streamUrl":"https://raspberrypi.your-tailnet.ts.net:8443/cam-your-private-path/"},{"id":"macbook","name":"MacBook Pro","kind":"Built-in camera","apiBase":"https://macbook.your-tailnet.ts.net:9443","streamUrl":"https://macbook.your-tailnet.ts.net:9444/mac-your-private-path/"}]' node fleet-site/verify-config.js --production
```

Then update each camera host CORS setting to include the deployed Vercel origin:

```text
https://your-fleet-site.vercel.app
```

The fleet site does not store dashboard passwords or stream-control passwords.
You type them in the browser. Each camera host validates its own passwords.

For this project, the intended production shape is:

```text
Vercel static dashboard -> browser -> private Tailscale HTTPS camera hosts
```

Vercel does not proxy camera traffic in production. Your phone must have
Tailscale connected before opening the deployed dashboard.

## Daily Use

1. Turn on Tailscale on your phone.
2. Open the fleet Vercel URL.
3. Enter the dashboard password.
4. Each reachable camera unlocks.
5. Use each camera card's control password field to turn that specific stream on
   or off.
6. Use `Fullscreen` on the camera you want to inspect closely.

If one camera is offline, the other cards still work.
