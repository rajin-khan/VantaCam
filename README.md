# VantaCam

VantaCam is a private live-camera console for a Raspberry Pi 5, a USB webcam,
Tailscale, MediaMTX, and a small Vercel-hosted dashboard.

The important idea: the Pi owns the camera and the stream. Vercel only hosts the
responsive control surface you can open from your phone. The camera path stays
inside your tailnet, and the stream can be turned fully on or fully off.

## System Shape

```text
USB webcam
  -> Raspberry Pi
  -> MediaMTX
  -> private WebRTC stream
  -> Tailscale Serve HTTPS
  -> Vercel dashboard in your browser
```

The dashboard has two gates:

- Dashboard password: unlocks the web console.
- Stream control password: allows `Turn On` and `Turn Off`.

When the stream is off, the MediaMTX service is stopped and disabled. The camera
feed is not available again until you turn it back on.

## Main Workflow

Use this day to day:

1. Keep the Raspberry Pi powered on and connected to Tailscale.
2. Turn on Tailscale on your phone or laptop.
3. Open the Vercel dashboard URL.
4. Log in with the dashboard password from `CAMERA-RUNBOOK.md`.
5. Enter the stream control password from `CAMERA-RUNBOOK.md`.
6. Press `Turn On` to start MediaMTX and load the feed.
7. Press `Turn Off` when you are done watching.

Your private values live in the ignored `CAMERA-RUNBOOK.md`. This public README
uses placeholders on purpose.

## What Each Folder Does

```text
bin/
  camctl.sh                 Password-gated command-line stream control.

pi/
  install-pi.sh             Installs/configures MediaMTX on the Pi.
  enable-tailscale-serve.sh Publishes Pi services through Tailscale Serve.

web/
  server.js                 Private dashboard API and local web server.
  public/                   Shared dashboard HTML, CSS, JS, and logo.
  env/                      Public environment templates.

vercel-site/
  index.html                Static dashboard shell for Vercel.
  api/config.js             Exposes PI_API_BASE to the browser.
  local-preview.js          Local Vercel-style preview server.
  assets/                   Same dashboard CSS, JS, and logo.
```

## Local Preview

Use this when you want to test the dashboard on your Mac before deploying.

Terminal 1:

```bash
node web/server.js
```

Terminal 2:

```bash
cd vercel-site
PI_API_BASE=http://127.0.0.1:3100 node local-preview.js
```

Open:

```text
http://127.0.0.1:3000/
```

What this means:

- `web/server.js` runs the same private API the Pi uses.
- `local-preview.js` acts like the Vercel site locally.
- `/api/*` and `/stream/*` are proxied through `localhost:3000`, so cookies and
  browser login behavior are easy to test.

Stop local preview:

```bash
lsof -tiTCP:3000 -sTCP:LISTEN | xargs kill
lsof -tiTCP:3100 -sTCP:LISTEN | xargs kill
```

## Command-Line Control

From the Mac:

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

What this means:

- `status` checks whether the stream service is active and enabled.
- `urls` prints the dashboard and stream URLs.
- `on` asks for the stream control password, then starts/enables MediaMTX.
- `off` asks for the stream control password, then stops/disables MediaMTX.

## Pi Backend Setup

On the Pi:

```bash
cd ~/camera-stream-pi
```

The Pi dashboard server should run on localhost port `3100`. A hosted-mode
`web/.env` uses this shape:

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
- `STREAM_HOST=127.0.0.1` keeps HLS proxying local.
- `PUBLIC_WEBRTC_URL` is the private HTTPS MediaMTX page shown in the iframe.
- `CORS_ORIGIN` allows only your Vercel site to call the Pi API from a browser.
- `COOKIE_SECURE=true` requires HTTPS cookies in hosted mode.
- `COOKIE_SAMESITE=None` lets the Vercel page authenticate against the Pi URL.

To reinstall or repair MediaMTX in Tailscale Serve mode:

```bash
sudo WEBRTC_HTTP_BIND_IP=127.0.0.1 INPUT_FORMAT=mjpeg VIDEO_DEVICE=/dev/video0 VIDEO_SIZE=1280x720 FRAMERATE=30 BITRATE=1200k ./install-pi.sh
```

That keeps the WebRTC web page private on `127.0.0.1:8889` so Tailscale Serve
can publish it over private HTTPS.

## Tailscale Serve

On the Pi:

```bash
sudo ./enable-tailscale-serve.sh
```

Expected private HTTPS routes:

```text
https://raspberrypi.your-tailnet.ts.net
https://raspberrypi.your-tailnet.ts.net:8443
```

What this does:

- Port `443` serves the private dashboard API/UI through Tailscale HTTPS.
- Port `8443` serves the private MediaMTX WebRTC page through Tailscale HTTPS.
- Access is tailnet-only.

Do not enable Tailscale Funnel for this project unless you intentionally want
the camera path reachable from the public internet.

## Vercel Deployment

Create a Vercel project with this root directory:

```text
vercel-site
```

Set this environment variable in Vercel:

```text
PI_API_BASE=https://raspberrypi.your-tailnet.ts.net
```

What Vercel hosts:

- The static dashboard HTML/CSS/JS.
- `/api/config.js`, which tells the browser where the private Pi API lives.

What Vercel does not store:

- Dashboard password.
- Stream control password.
- Camera stream secret path.
- Tailscale credentials.

## Private Files

These are intentionally ignored by Git:

```text
CAMERA-RUNBOOK.md
camera.env
web/.env
pi/live/*
web/systemd/*.live.service
.vercel/
```

Keep real passwords, hashes, session secrets, private stream paths, live systemd
files, and Vercel project metadata in those ignored files only.

## Safe To Push

Public-safe files include:

```text
README.md
camera.env.example
web/.env.example
web/env/*.example
bin/
pi/
web/
vercel-site/
```

Before pushing to a public GitHub repo, run:

```bash
git add --dry-run .
```

Only public templates and source files should appear. If `CAMERA-RUNBOOK.md`,
`web/.env`, `camera.env`, `.vercel/`, or any live private file appears, stop and
fix `.gitignore` before pushing.

## References

- Tailscale Serve: https://tailscale.com/docs/features/tailscale-serve
- Tailscale Serve CLI: https://tailscale.com/docs/reference/cli/serve
- Vercel environment variables: https://vercel.com/docs/environment-variables
