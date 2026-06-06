# VantaCam

![VantaCam banner](docs/assets/vantacam-banner.png)

VantaCam is a private live-camera console for a Raspberry Pi, a USB webcam,
MediaMTX, Tailscale, and a small Vercel-hosted dashboard.

It is designed for one very practical workflow:

1. Leave a Raspberry Pi powered on with a USB webcam attached.
2. Open a private dashboard from your phone or laptop.
3. Log in.
4. Turn the camera stream on only when you want to watch it.
5. Turn the stream fully off when you are done.

When the stream is off, the MediaMTX service is stopped and disabled. The camera
path is not available again until an authenticated control command turns it back
on.

## The Short Version

The Pi does the real work. It owns the camera, runs MediaMTX, and exposes a
private dashboard API. Vercel only hosts a static web UI that points back to the
Pi through Tailscale.

```text
USB webcam
  -> Raspberry Pi
  -> MediaMTX
  -> private WebRTC stream
  -> Tailscale Serve HTTPS
  -> Vercel dashboard
  -> your phone or laptop
```

This keeps the camera system small and understandable:

- The camera feed stays on the Pi.
- The public repo contains source code and templates only.
- Private passwords, stream paths, and live URLs stay in ignored local files.
- Vercel does not store the camera password or stream-control password.
- Tailscale is the network boundary.

## Who This Is For

This project is for someone who wants a private remote camera without turning
the webcam into a public internet device.

You should be comfortable with:

- Running shell commands on a Raspberry Pi.
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
HTML, CSS, and JavaScript. It asks the Pi backend where the stream is and sends
login/control requests to the Pi.

Relevant folder:

```text
vercel-site/
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
│   └── assets/
│       Public README images.
│
├── pi/
│   ├── install-pi.sh
│   │   Installs and configures MediaMTX on the Raspberry Pi.
│   ├── diagnose-pi.sh
│   │   Prints useful Pi, camera, service, and network diagnostics.
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
├── vercel-site/
│   ├── index.html
│   │   Static dashboard page deployed to Vercel.
│   ├── api/config.js
│   │   Small Vercel function that exposes PI_API_BASE to the browser.
│   ├── local-preview.js
│   │   Local Vercel-style preview server.
│   └── assets/
│       Dashboard CSS, JavaScript, and logo assets.
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
vercel-site/
```

The files are intentionally similar. `web/public/` is what the Pi backend can
serve directly. `vercel-site/` is the copy meant for Vercel.

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

## Local Vercel-Style Preview

Use this when you want to test the same frontend shape that Vercel will serve.

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
sudo WEBRTC_HTTP_BIND_IP=127.0.0.1 INPUT_FORMAT=mjpeg VIDEO_DEVICE=/dev/video0 VIDEO_SIZE=1280x720 FRAMERATE=30 BITRATE=1200k ./install-pi.sh
```

What the important options mean:

- `WEBRTC_HTTP_BIND_IP=127.0.0.1` keeps the MediaMTX WebRTC page local so
  Tailscale Serve can publish it privately.
- `INPUT_FORMAT=mjpeg` is often a good USB webcam format.
- `VIDEO_DEVICE=/dev/video0` is the webcam device path.
- `VIDEO_SIZE=1280x720` sets 720p video.
- `FRAMERATE=30` requests 30 FPS.
- `BITRATE=1200k` keeps bandwidth reasonable.

Run diagnostics:

```bash
./pi/diagnose-pi.sh
```

Use diagnostics when the camera does not appear, the service will not start, or
the stream URL does not load.

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

## Vercel Deployment

Create a Vercel project with this root directory:

```text
vercel-site
```

Set this Vercel environment variable:

```text
PI_API_BASE=https://raspberrypi.your-tailnet.ts.net
```

What this means:

- Vercel serves the static dashboard.
- The browser uses `PI_API_BASE` to find the private Pi API.
- Passwords and stream secrets do not belong in Vercel.

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
vercel-site/
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
2. Read `web/public/assets/app.js` to see how the browser logs in, refreshes
   status, turns the stream on/off, and renders the iframe.
3. Read `web/public/index.html` and `web/public/assets/styles.css` to understand
   the dashboard UI.
4. Read `vercel-site/local-preview.js` to understand the local Vercel-style
   proxy.
5. Read `vercel-site/api/config.js` to understand how Vercel passes the Pi API
   URL to the browser.
6. Read `bin/camctl.sh` to understand command-line stream control.
7. Read `pi/install-pi.sh` and `pi/enable-tailscale-serve.sh` to understand the
   Pi setup.

That order follows the normal request path: browser UI, backend API, stream
control, Pi service setup.

## References

- Tailscale Serve: https://tailscale.com/docs/features/tailscale-serve
- Tailscale Serve CLI: https://tailscale.com/docs/reference/cli/serve
- MediaMTX: https://github.com/bluenviron/mediamtx
- Vercel environment variables: https://vercel.com/docs/environment-variables
