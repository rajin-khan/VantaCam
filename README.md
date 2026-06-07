# VantaCam

![VantaCam banner](docs/assets/vantacam-banner.png)

VantaCam is a private live-camera console for a Raspberry Pi or Mac camera host,
MediaMTX, Tailscale, and a small Vercel-hosted dashboard.

It is designed for one very practical workflow:

1. Leave a camera host powered on: a Raspberry Pi with a USB webcam, or an
   optional Mac host.
2. Open a private dashboard from your phone or laptop.
3. Log in.
4. Turn a camera stream on only when you want to watch it.
5. Turn the stream fully off when you are done.

When the stream is off, the MediaMTX service is stopped and disabled. The camera
path is not available again until an authenticated control command turns it back
on.

## The Short Version

The camera host does the real work. It owns the camera, runs MediaMTX, and
exposes a private dashboard API. Vercel only hosts a static web UI that points
back to your camera hosts through Tailscale.

```text
Camera
  -> Raspberry Pi or Mac host
  -> MediaMTX
  -> private WebRTC stream
  -> Tailscale Serve HTTPS
  -> Vercel dashboard
  -> your phone or laptop
```

This keeps the camera system small and understandable:

- The camera feed stays on the camera host.
- The public repo contains source code and templates only.
- Private passwords, stream paths, and live URLs stay in ignored local files.
- Vercel does not store the camera password or stream-control password.
- Tailscale is the network boundary.

## Who This Is For

This project is for someone who wants a private remote camera without turning
the webcam into a public internet device.

You should be comfortable with:

- Running shell commands on a Raspberry Pi or Mac.
- Editing `.env` files.
- Using Tailscale.
- Deploying a simple static site to Vercel.

You do not need to understand every part of MediaMTX or WebRTC before using the
repo. This README explains the moving pieces in plain language, then points to
the files that implement each piece.

## Core Concepts

### The Raspberry Pi is the camera host

The Pi has the webcam plugged into it. MediaMTX runs on the Pi and converts the
camera input into stream formats the browser can view.

Relevant files:

```text
pi/install-pi.sh
pi/diagnose-pi.sh
web/server.js
web/systemd/camera-dashboard.service
```

### MediaMTX is the stream engine

MediaMTX is the service that talks to the USB webcam and serves the stream. In
this project it is treated as something you can start or stop completely.

Relevant file:

```text
pi/install-pi.sh
```

### Tailscale is the private network

Tailscale lets your phone, laptop, and Pi talk to each other as if they are on a
private network, even when they are in different physical locations.

Tailscale Serve can publish a local Pi service as a private HTTPS URL that only
tailnet members can reach.

Relevant file:

```text
pi/enable-tailscale-serve.sh
```

### Vercel hosts the dashboard shell

The Vercel app is intentionally boring from a security perspective. It is static
HTML, CSS, and JavaScript. It loads your configured Pi and Mac camera hosts,
then sends login/control requests directly to those private tailnet hosts from
your browser.

Relevant folder:

```text
fleet-site/
```

### The dashboard has two passwords

There are two separate checks:

- Dashboard password: unlocks the web console.
- Stream control password: allows the stream to be turned on or off.

That means someone needs dashboard access and the separate control password
before they can power the camera stream.

## Repository Map

```text
.
├── bin/
│   └── camctl.sh
│       Password-gated command-line helper for status, URLs, on, and off.
│
├── docs/
│   ├── assets/
│       Public README images.
│   └── TROUBLESHOOTING.md
│       Public-safe recovery guide for common Pi, camera, and stream issues.
│
├── fleet-site/
│   ├── index.html
│   │   Multi-camera Vercel dashboard.
│   ├── api/config.js
│   │   Exposes configured camera hosts to the browser.
│   ├── cameras.example.json
│   │   Public-safe multi-camera config example.
│   ├── verify-config.js
│   │   Checks local and production fleet camera config.
│   └── local-preview.js
│       Local preview server for the fleet dashboard.
│
├── mac/
│   ├── install-mac.sh
│   │   Installs a separate macOS camera host add-on.
│   ├── enable-tailscale-cert-proxy.sh
│   │   Fallback private HTTPS proxy for Macs where Tailscale Serve does not persist.
│   ├── vantacam_host.py
│   │   Python dashboard/control API for the Mac host.
│   ├── vantacam_https_proxy.py
│   │   Tiny HTTPS reverse proxy used by the Mac fallback.
│   └── README.md
│       Mac-specific setup and operations notes.
│
├── pi/
│   ├── install-pi.sh
│   │   Installs and configures MediaMTX on the Raspberry Pi.
│   ├── diagnose-pi.sh
│   │   Prints useful Pi, camera, service, and network diagnostics.
│   ├── health-check.sh
│   │   Checks the camera, Tailscale, dashboard, and MediaMTX services.
│   └── enable-tailscale-serve.sh
│       Publishes local Pi services through Tailscale Serve.
│
├── web/
│   ├── server.js
│   │   Private dashboard API and local web server.
│   ├── public/
│   │   The shared dashboard UI served by the Pi backend.
│   ├── env/
│   │   Public example environment files for Mac/Pi setups.
│   └── systemd/
│       Systemd service and sudoers templates for the Pi dashboard.
│
├── camera.env.example
├── web/.env.example
└── README.md
```

## How The Dashboard Works

The dashboard is split into frontend and backend pieces.

The frontend lives in two places:

```text
web/public/
fleet-site/
```

`web/public/` is the single-host dashboard served directly by a camera backend.
`fleet-site/` is the Vercel dashboard for the Pi + Mac fleet.

The backend is:

```text
web/server.js
```

It handles:

- `POST /api/login`
- `POST /api/logout`
- `GET /api/session`
- `GET /api/status`
- `POST /api/control`
- `/stream/*` proxying for local/HLS workflows
- serving the dashboard assets

The browser loads:

```text
/api/config.js
```

That small config script tells the dashboard where the Pi API is. In local
preview it can point to `http://127.0.0.1:3100`. In the deployed Vercel setup it
points to the Pi Tailscale Serve URL.

## Main Day-To-Day Workflow

Use this after the Pi and Vercel deployment are already configured.

1. Make sure the Pi is powered on.
2. Make sure the Pi is connected to Tailscale.
3. Turn on Tailscale on your phone or laptop.
4. Open the Vercel dashboard URL.
5. Enter the dashboard password.
6. Enter the stream control password.
7. Press `Turn On`.
8. Watch the feed.
9. Press `Turn Off` when finished.

The private dashboard URL, stream path, and real passwords belong in
`CAMERA-RUNBOOK.md`, which is intentionally ignored by Git.

## Command-Line Control

The web dashboard is convenient, but the command-line helper is the simplest
way to start or stop the camera path directly.

From this repo on your Mac:

```bash
./bin/camctl.sh status
./bin/camctl.sh urls
./bin/camctl.sh on
./bin/camctl.sh off
```

From the Pi:

```bash
cd ~/camera-stream-pi
./camctl.sh status
./camctl.sh urls
./camctl.sh on
./camctl.sh off
```

What the commands mean:

- `status` checks whether MediaMTX is active and enabled.
- `urls` prints the known dashboard and stream URLs.
- `on` asks for the stream control password, then starts/enables MediaMTX.
- `off` asks for the stream control password, then stops/disables MediaMTX.

## Local Development

Use local development when you want to test the dashboard UI and backend from
your Mac.

Start the private backend:

```bash
node web/server.js
```

Then open:

```text
http://127.0.0.1:3100/
```

This serves the dashboard directly from `web/public/`.

## Local Fleet Preview

Use this when you want to test the same frontend shape that Vercel will serve.

Create an ignored local camera config, then start the preview:

```bash
cp fleet-site/cameras.example.json fleet-site/cameras.local.json
cd fleet-site
node verify-config.js
node local-preview.js
```

Open:

```text
http://127.0.0.1:3300/
```

What this does:

- `web/server.js` runs the private API.
- `local-preview.js` serves the Vercel-style static frontend.
- `/api/*` and `/stream/*` are proxied through `localhost:3000`.
- Browser cookies stay on one origin during local testing.

Stop local preview:

```bash
lsof -tiTCP:3000 -sTCP:LISTEN | xargs kill
lsof -tiTCP:3100 -sTCP:LISTEN | xargs kill
```

## Raspberry Pi Setup

On the Pi, the working copy usually lives at:

```bash
cd ~/camera-stream-pi
```

Install or repair MediaMTX:

```bash
sudo WEBRTC_HTTP_BIND_IP=127.0.0.1 INPUT_FORMAT=mjpeg VIDEO_DEVICE=auto VIDEO_SIZE=1280x720 FRAMERATE=30 BITRATE=1200k ./install-pi.sh
```

What the important options mean:

- `WEBRTC_HTTP_BIND_IP=127.0.0.1` keeps the MediaMTX WebRTC page local so
  Tailscale Serve can publish it privately.
- `INPUT_FORMAT=mjpeg` is often a good USB webcam format.
- `VIDEO_DEVICE=auto` prefers a stable `/dev/v4l/by-id/...` camera path, then
  falls back to `/dev/video0` when no stable path exists.
- `VIDEO_SIZE=1280x720` sets 720p video.
- `FRAMERATE=30` requests 30 FPS.
- `BITRATE=1200k` keeps bandwidth reasonable.

For maximum USB robustness, use the camera identity path directly after you
know it:

```bash
ls -l /dev/v4l/by-id/
```

Then set `VIDEO_DEVICE` to the `*-video-index0` path for the USB webcam:

```text
VIDEO_DEVICE=/dev/v4l/by-id/usb-Your_Webcam_Name-video-index0
```

That path follows the camera itself, so moving the webcam to a different USB
port should not change the configured device.

Run diagnostics:

```bash
./pi/diagnose-pi.sh
```

Use diagnostics when the camera does not appear, the service will not start, or
the stream URL does not load.

Run the health check:

```bash
./pi/health-check.sh
```

Run the health check with repair mode:

```bash
./pi/health-check.sh --repair
```

Repair mode starts enabled services if they are unexpectedly stopped. It does
not force the camera stream on if you previously turned it off, because `off`
intentionally disables MediaMTX.

For symptom-by-symptom recovery steps, see
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Power Cuts And USB Reconnects

VantaCam is built to survive normal Pi restarts.

After power returns:

```text
Pi boots
Tailscale reconnects
camera-dashboard starts if enabled
MediaMTX starts only if it was enabled before power loss
```

That means the stream preserves your last intent:

- If you left the stream on, MediaMTX is enabled and should come back after boot.
- If you turned the stream off, MediaMTX is disabled and should stay off.

The dashboard service and MediaMTX service both use systemd restart behavior.
MediaMTX also has `runOnInitRestart: yes`, so if ffmpeg exits because the camera
temporarily disappears, MediaMTX keeps trying to start the camera path again.

The main thing to avoid is a fragile `/dev/video0` dependency. Linux can rename
video devices after reboot or replug. Use `VIDEO_DEVICE=auto` or a direct
`/dev/v4l/by-id/...` path to bind the stream to the webcam identity instead of
the changing device number.

If the camera is unplugged while the stream is on:

- The stream will fail while the camera is missing.
- MediaMTX remains running.
- When the same camera returns, ffmpeg should be restarted by MediaMTX.
- If it does not recover, run `./pi/health-check.sh --repair` or restart the
  stream with `./camctl.sh off` followed by `./camctl.sh on`.

Without a UPS, use a high-quality power supply and a good microSD card. An SSD
boot drive is better if you later want to reduce filesystem-corruption risk from
frequent sudden power cuts.

## Pi Dashboard Environment

The Pi backend reads configuration from `web/.env`. The real file is ignored by
Git. Use the example files as templates.

Hosted mode usually looks like this:

```text
HOST=127.0.0.1
PORT=3100
STREAM_HOST=127.0.0.1
PUBLIC_WEBRTC_URL=https://raspberrypi.your-tailnet.ts.net:8443/cam-your-private-path/
CORS_ORIGIN=https://your-vercel-app.vercel.app
COOKIE_SECURE=true
COOKIE_SAMESITE=None
```

What each value does:

- `HOST=127.0.0.1` keeps the dashboard API local to the Pi.
- `PORT=3100` is the local dashboard API port.
- `STREAM_HOST=127.0.0.1` keeps local stream proxying private.
- `PUBLIC_WEBRTC_URL` is the private MediaMTX WebRTC page loaded by the iframe.
- `CORS_ORIGIN` allows only your Vercel dashboard origin to call the Pi API.
- `COOKIE_SECURE=true` requires HTTPS cookies.
- `COOKIE_SAMESITE=None` allows the Vercel page to authenticate with the Pi API
  across origins.

## Tailscale Serve

Enable Tailscale Serve on the Pi:

```bash
sudo ./pi/enable-tailscale-serve.sh
```

Expected private HTTPS routes:

```text
https://raspberrypi.your-tailnet.ts.net
https://raspberrypi.your-tailnet.ts.net:8443
```

What those routes mean:

- Port `443` publishes the dashboard API/UI through private HTTPS.
- Port `8443` publishes the MediaMTX WebRTC page through private HTTPS.
- Only devices in your tailnet should be able to reach them.

Do not enable Tailscale Funnel for this project unless you intentionally want to
expose the camera path to the public internet.

## Optional Mac Camera Host

The `mac/` folder is a separate add-on for turning a Mac into another VantaCam
camera host. It does not modify the Raspberry Pi implementation.

Use this when you want a MacBook camera or Mac-attached USB camera to behave like
the Pi host: dashboard login, separate stream-control password, and MediaMTX off
until you explicitly turn it on.

List available Mac cameras:

```bash
./mac/install-mac.sh --list-cameras
```

Install with the first AVFoundation camera:

```bash
./mac/install-mac.sh --camera 0 --stream-name mac-your-private-path --public-host 100.x.y.z --host 0.0.0.0 --port 3200
```

Install for Vercel/fleet mode through Tailscale Serve HTTPS:

```bash
./mac/install-mac.sh \
  --camera 0 \
  --stream-name mac-your-private-path \
  --public-host macbook.your-tailnet.ts.net \
  --public-webrtc-url https://macbook.your-tailnet.ts.net:8443/mac-your-private-path/ \
  --host 127.0.0.1 \
  --port 3200 \
  --cors-origin https://your-fleet-site.vercel.app \
  --cookie-secure true \
  --cookie-samesite None
```

What this creates on the Mac:

- `~/Library/LaunchAgents/com.vantacam.host.plist` keeps the Mac dashboard API
  available.
- `~/Library/LaunchAgents/com.vantacam.mediamtx.plist` is loaded only when the
  stream is turned on.
- `~/Library/LaunchAgents/com.vantacam.camera.plist` publishes camera frames
  into MediaMTX only while the stream is turned on.
- `~/Library/Application Support/VantaCam/logs/` stores Mac host, MediaMTX, and
  ffmpeg logs.
- `~/.vantacam/bin/run-camera` is the generated ffmpeg camera runner.

Open the Mac dashboard from a tailnet device:

```text
http://100.x.y.z:3200/
```

Open the Mac WebRTC stream only after the stream is on:

```text
http://100.x.y.z:8889/mac-your-private-path/
```

Use `GET`, a browser, or the dashboard status when checking the WebRTC path.
MediaMTX can return `404` to a `HEAD` request even when the page works in a
browser. If the Mac dashboard says MediaMTX is active but `pathReady` is false,
MediaMTX is running but ffmpeg has not published camera frames. Check:

```bash
tail -100 "$HOME/Library/Application Support/VantaCam/logs/ffmpeg.log"
tail -100 "$HOME/Library/Application Support/VantaCam/logs/mediamtx.out.log"
```

On macOS, camera access can require a one-time local privacy approval. If the Mac
is remote, use Screen Sharing or physical access to approve Camera access for the
terminal/ffmpeg path, then turn the stream off and on again.

Enable private Tailscale Serve HTTPS on the Mac:

```bash
./mac/enable-tailscale-serve.sh
```

Expected private HTTPS routes:

```text
https://macbook.your-tailnet.ts.net
https://macbook.your-tailnet.ts.net:8443
```

If `tailscale serve --bg` prints success but `tailscale serve status` remains
empty, use the Mac cert-proxy fallback:

```bash
./mac/enable-tailscale-cert-proxy.sh
```

That publishes private HTTPS on high Tailnet ports:

```text
https://macbook.your-tailnet.ts.net:9443
https://macbook.your-tailnet.ts.net:9444
```

For fleet config, use port `9443` as the Mac `apiBase` and port `9444` for the
Mac `streamUrl`.

## Fleet Dashboard Deployment

Use this when you want one Vercel page that shows multiple cameras, such as the
Pi camera and a Mac camera.

This is the folder to deploy for the phone dashboard:

```text
fleet-site
```

Set exactly one Vercel environment variable:

```text
FLEET_CAMERAS_JSON=[{"id":"pi-main","name":"Raspberry Pi","kind":"USB webcam","apiBase":"https://raspberrypi.your-tailnet.ts.net","streamUrl":"https://raspberrypi.your-tailnet.ts.net:8443/cam-your-private-path/"},{"id":"macbook","name":"MacBook Pro","kind":"Built-in camera","apiBase":"https://macbook.your-tailnet.ts.net:9443","streamUrl":"https://macbook.your-tailnet.ts.net:9444/mac-your-private-path/"}]
```

What this means:

- `fleet-site` is the multi-camera dashboard.
- `apiBase` is each camera host dashboard API.
- `streamUrl` is each camera host WebRTC page.
- These URLs should be private Tailscale Serve HTTPS URLs.
- The fleet site does not store dashboard or control passwords.

Use [fleet-site/.env.example](fleet-site/.env.example) as the public-safe shape,
then set the real private value in Vercel.

Each camera host must allow the fleet page origin in its own CORS config:

```text
CORS_ORIGIN=https://your-fleet-site.vercel.app
COOKIE_SECURE=true
COOKIE_SAMESITE=None
```

For local preview:

```bash
cp fleet-site/cameras.example.json fleet-site/cameras.local.json
node fleet-site/verify-config.js
cd fleet-site
node local-preview.js
```

Open:

```text
http://127.0.0.1:3300/
```

Local preview proxies camera API calls through `127.0.0.1:3300`, so it can test
direct tailnet HTTP hosts without cross-site cookie trouble. Production Vercel
does not have tailnet access from its serverless functions, so the deployed page
uses browser-to-camera HTTPS directly.

For production Vercel, include the deployed fleet origin on each camera host:

```text
https://your-fleet-site.vercel.app
```

Before deploying, validate the exact `FLEET_CAMERAS_JSON` value:

```bash
FLEET_CAMERAS_JSON='[...]' node fleet-site/verify-config.js --production
```

## Security Model

VantaCam is meant to be private by default.

Security boundaries:

- Tailscale controls who can reach the Pi service.
- Dashboard login controls who can open the web console.
- Stream control password controls who can start or stop MediaMTX.
- MediaMTX is disabled when the stream is off.
- Private values stay out of Git.

Things this repo intentionally avoids:

- Public camera URLs.
- Tailscale Funnel.
- Hardcoded real passwords.
- Hardcoded real stream paths.
- Committing live `.env` files.

## Private Files

These files are intentionally ignored:

```text
CAMERA-RUNBOOK.md
camera.env
web/.env
pi/live/*
web/systemd/*.live.service
.vercel/
```

Keep these values private:

- Dashboard password.
- Stream control password.
- Password hashes.
- Session secrets.
- Private stream path.
- Real Tailscale Serve URLs.
- Live systemd files.
- Vercel project metadata.

## Public Repo Safety

Before pushing to a public GitHub repo, run:

```bash
git add --dry-run .
```

Only public source, templates, and assets should appear.

Safe public files include:

```text
README.md
docs/assets/vantacam-banner.png
camera.env.example
web/.env.example
web/env/*.example
bin/
pi/
web/
mac/
fleet-site/
```

If any of these appear in the dry run, stop and fix `.gitignore`:

```text
CAMERA-RUNBOOK.md
camera.env
web/.env
.vercel/
pi/live/*
web/systemd/*.live.service
```

## How To Read The Code

Start here:

1. Read `web/server.js` to understand auth, status checks, control commands,
   CORS, cookies, and stream proxying.
2. Read `fleet-site/assets/app.js` to see how the Vercel dashboard logs into
   each camera host, refreshes status, turns streams on/off, and renders the
   iframes.
3. Read `fleet-site/index.html` and `fleet-site/assets/styles.css` to
   understand the production phone dashboard UI.
4. Read `fleet-site/local-preview.js` to understand the local preview proxy.
5. Read `fleet-site/api/config.js` to understand how Vercel exposes camera host
   config from `FLEET_CAMERAS_JSON`.
6. Read `mac/vantacam_host.py` to understand the Mac camera host API.
7. Read `bin/camctl.sh` to understand command-line stream control.
8. Read `pi/install-pi.sh`, `pi/diagnose-pi.sh`, `pi/health-check.sh`, and
   `pi/enable-tailscale-serve.sh` to understand the Pi setup and recovery tools.

That order follows the normal request path: browser UI, backend API, stream
control, Pi service setup.

## References

- Tailscale Serve: https://tailscale.com/docs/features/tailscale-serve
- Tailscale Serve CLI: https://tailscale.com/docs/reference/cli/serve
- MediaMTX: https://github.com/bluenviron/mediamtx
- Vercel environment variables: https://vercel.com/docs/environment-variables
