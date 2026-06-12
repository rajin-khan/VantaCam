# Troubleshooting VantaCam

This guide helps diagnose the common failure modes for a Raspberry Pi USB
webcam running VantaCam with MediaMTX, Tailscale, and the dashboard service.

It is written for a public repo, so it uses placeholder URLs and paths. Keep
real passwords, Tailscale URLs, IP addresses, and private stream paths in your
ignored `CAMERA-RUNBOOK.md`.

## First Command To Run

On the Pi:

```bash
cd ~/camera-stream-pi
./pi/health-check.sh
```

If the output says a service is enabled but stopped:

```bash
./pi/health-check.sh --repair
```

Repair mode starts services that are already enabled. It does not turn the
camera stream on if you intentionally turned it off, because `camctl.sh off`
disables MediaMTX on purpose.

## Healthy States

When the stream is intentionally off, healthy output looks like this:

```text
ok: camera device exists: /dev/v4l/by-id/...
ok: tailscaled is active
ok: camera-dashboard is active
ok: dashboard API responded
ok: mediamtx is disabled; stream is intentionally off
ok: health check passed
```

When the stream is on, healthy output looks like this:

```text
ok: camera device exists: /dev/v4l/by-id/...
ok: tailscaled is active
ok: camera-dashboard is active
ok: dashboard API responded
ok: mediamtx is active
ok: MediaMTX WebRTC page responded
ok: health check passed
```

## After A Power Cut

Expected behavior:

```text
Power returns
Pi boots
Tailscale reconnects
camera-dashboard starts
MediaMTX starts only if it was enabled before power loss
```

This means the stream preserves your last intent:

- If the stream was on before power loss, it should come back.
- If the stream was off before power loss, it should stay off.

Run:

```bash
cd ~/camera-stream-pi
./pi/health-check.sh
```

If the Pi is not reachable:

1. Wait a minute or two for boot.
2. Check that the Pi has power.
3. Check the Pi in the Tailscale admin/device list.
4. Try SSH over its Tailscale hostname or IP.

## Camera Missing

Symptom:

```text
fail: camera device is missing
```

Check what Linux sees:

```bash
ls -l /dev/video*
ls -l /dev/v4l/by-id/
ls -l /dev/v4l/by-path/
```

Recommended camera setting:

```text
VIDEO_DEVICE=/dev/v4l/by-id/usb-Your_Webcam_Name-video-index0
```

Why: `/dev/video0` can change after reboot or unplug/replug. A
`/dev/v4l/by-id/...` path follows the webcam identity and usually survives USB
port changes.

If no `/dev/v4l/by-id/` entry appears:

1. Reseat the USB cable.
2. Try another USB port.
3. Try a different cable if the camera uses one.
4. Run diagnostics:

```bash
./pi/diagnose-pi.sh
```

## Stream Is Off

Symptom:

```text
ok: mediamtx is disabled; stream is intentionally off
```

This is not a bug. It means the stream was turned off with the dashboard or:

```bash
./camctl.sh off
```

Turn it on:

```bash
./camctl.sh on
```

The command asks for the stream control password.

## Stream Pane Shows 502

Symptom:

```text
Failed to load resource: the server responded with a status of 502
```

If this happens on the WebRTC URL, Tailscale Serve is reachable but the service
behind it is not. On the Pi, compare the Serve target with the MediaMTX WebRTC
listener:

```bash
sudo systemctl status mediamtx --no-pager
grep -nE 'webrtcAddress|webrtcLocal|webrtcAdditionalHosts' /etc/mediamtx/mediamtx.yml
tailscale serve status
```

Then test the MediaMTX page directly:

```bash
curl -i http://127.0.0.1:8889/YOUR_STREAM_PATH/
curl -i http://YOUR_TAILSCALE_IP:8889/YOUR_STREAM_PATH/
```

If MediaMTX is bound to the Tailscale IP instead of `127.0.0.1`, the Serve
target for port `8443` must point at that Tailscale IP:

```bash
sudo tailscale serve --https=8443 off
sudo tailscale serve --bg --https=8443 http://YOUR_TAILSCALE_IP:8889
```

The helper script also handles this automatically:

```bash
sudo ./pi/enable-tailscale-serve.sh
```

## Replay Buffer Missing

Symptom:

```text
The camera works, but the Replay button says no last-session buffer is available.
```

Check whether rewind is enabled in the host environment:

```text
REWIND_ENABLED=true
REWIND_MINUTES=30
REWIND_DIR=/run/vantacam-rewind
```

On the Pi, check the recorder service:

```bash
sudo systemctl status vantacam-rewind --no-pager
ls -lh /run/vantacam-rewind/
```

Expected while the stream is on:

```text
index.m3u8
segment_00000.ts
segment_00001.ts
...
```

Expected after turning the stream off:

```text
vantacam-rewind is stopped
index.m3u8 and recent segment files remain
```

If the service is failing, inspect the log:

```bash
sudo journalctl -u vantacam-rewind -n 120 --no-pager
```

Common causes:

- `REWIND_SOURCE_URL` points at the wrong stream path.
- MediaMTX is not active yet when the recorder starts.
- `REWIND_DIR` is not writable by the recorder service user.
- The browser does not support HLS playback in a plain video element.

## Dashboard Does Not Load

Check the dashboard service:

```bash
sudo systemctl status camera-dashboard --no-pager
sudo journalctl -u camera-dashboard -n 100 --no-pager
```

Check whether the dashboard is listening:

```bash
ss -lntp | grep 3100
```

Check the dashboard health endpoint:

```bash
curl -fsS http://127.0.0.1:3100/api/session
```

If your `web/.env` binds `HOST` to a Tailscale IP instead of `127.0.0.1`, use
that configured host:

```bash
curl -fsS http://100.x.y.z:3100/api/session
```

Common causes:

- `camera-dashboard.service` is not running.
- `web/.env` has a bad `HOST` or `PORT`.
- Node is missing or installed in a different path.
- Tailscale is disconnected when using a tailnet IP.

Try:

```bash
sudo systemctl restart camera-dashboard
./pi/health-check.sh
```

## Dashboard Login Fails

Check:

- You are using the dashboard password, not the stream control password.
- `APP_PASSWORD_SHA256` in `web/.env` matches the password you expect.
- The browser is reaching the same backend you configured.
- If using Vercel, `FLEET_CAMERAS_JSON` points to the correct private Tailscale
  Serve URLs for each camera host.

For local preview, use:

```bash
cd fleet-site
node verify-config.js
node local-preview.js
```

## Phone Login Loops Or Shows Unreachable

Symptom:

```text
The Vercel dashboard loads on a phone, but the Pi card says unreachable,
locked, or asks you to log in again after a successful login.
```

First check that the phone itself can reach the Pi over Tailscale. On the
phone, while Tailscale is connected, open:

```text
https://YOUR_PI_TAILSCALE_HOSTNAME.ts.net/api/session
```

Expected result:

```json
{"authenticated":false}
```

That means the phone can reach the Pi API. If it cannot load, check the
Tailscale app on the phone, make sure it is connected, and make sure Tailscale
DNS/MagicDNS is enabled for the device.

If the direct Pi URL works but the Vercel dashboard still loops, redeploy the
latest `fleet-site` code. The fleet dashboard uses a signed bearer session
fallback so iOS browsers do not have to preserve third-party cookies from the
Pi domain.

Then open:

```text
http://127.0.0.1:3000/
```

## Turn On / Turn Off Fails

Check:

- You are using the stream control password.
- `CONTROL_PASSWORD_SHA256` exists in both `web/.env` and `camera.env`.
- The dashboard backend can run the allowed systemd commands.
- `mediamtx.service` exists.

Commands:

```bash
sudo systemctl status mediamtx --no-pager
sudo journalctl -u mediamtx -n 100 --no-pager
./pi/health-check.sh
```

If the web button fails but the CLI works, check dashboard logs:

```bash
sudo journalctl -u camera-dashboard -n 100 --no-pager
```

## WebRTC Page Does Not Respond

Check MediaMTX:

```bash
sudo systemctl status mediamtx --no-pager
sudo journalctl -u mediamtx -n 100 --no-pager
```

Check ports:

```bash
ss -lntp | grep -E '(:8888|:8889|:8189)'
```

Check the WebRTC page directly:

```bash
curl -fsS -o /tmp/vantacam-webrtc.html http://127.0.0.1:8889/cam-your-private-path/
```

If MediaMTX is bound to a Tailscale IP, use that instead:

```bash
curl -fsS -o /tmp/vantacam-webrtc.html http://100.x.y.z:8889/cam-your-private-path/
```

Use `GET`, not `HEAD`, for this check. MediaMTX may return `404` to a `HEAD`
request even when the WebRTC HTML page works in a browser.

Common causes:

- MediaMTX is disabled because the stream is off.
- The camera is missing.
- `VIDEO_DEVICE` points to a stale `/dev/videoN`.
- MediaMTX is listening on a different host than the URL you are testing.
- Tailscale Serve is not configured for the hosted HTTPS mode.

## Vercel Page Loads But Cannot Reach A Camera

Check the Vercel environment variable:

```text
FLEET_CAMERAS_JSON=[{"apiBase":"https://raspberrypi.your-tailnet.ts.net","streamUrl":"https://raspberrypi.your-tailnet.ts.net:8443/cam-your-private-path/"}]
```

Check each camera host CORS value:

```text
CORS_ORIGIN=https://your-vercel-app.vercel.app
COOKIE_SECURE=true
COOKIE_SAMESITE=None
```

The Vercel URL must exactly match `CORS_ORIGIN`.

Also check:

```bash
tailscale serve status
```

You should see private HTTPS routes for the dashboard API and WebRTC page.

Do not use Tailscale Funnel unless you intentionally want public internet
exposure.

## Mac Host Dashboard Works But Stream Is Missing

Symptom:

```text
Dashboard login works
Turn On succeeds
Status says pathReady is false, or the browser does not show video
```

Meaning: MediaMTX may be running, but ffmpeg has not published camera frames to
the stream path yet. If you are testing with `curl -I`, retry with a browser or
with a normal `GET`; `HEAD` can return `404` on MediaMTX even when the page is
available.

Check logs on the Mac:

```bash
tail -100 "$HOME/Library/Application Support/VantaCam/logs/ffmpeg.log"
tail -100 "$HOME/Library/Application Support/VantaCam/logs/mediamtx.out.log"
```

Common causes:

- macOS has not granted camera permission to the terminal/ffmpeg path.
- The built-in camera is unavailable because the MacBook lid is closed.
- Another app is already using the camera.
- The selected AVFoundation camera index is wrong.
- The camera does not like the requested pixel format or resolution.

List cameras again:

```bash
./mac/install-mac.sh --list-cameras
```

Try a conservative reinstall:

```bash
./mac/install-mac.sh --camera 0 --video-size 640x480 --framerate 15 --pixel-format uyvy422
```

Direct camera probe:

```bash
"$HOME/.vantacam/bin/ffmpeg" \
  -hide_banner \
  -loglevel info \
  -f avfoundation \
  -pixel_format nv12 \
  -framerate 30 \
  -video_size 1280x720 \
  -i "0:none" \
  -t 3 \
  -an \
  -f null -
```

If the direct probe hangs before frames appear, fix macOS camera access or camera
physical state first. VantaCam cannot publish frames until ffmpeg can read frames
locally.

## Mac Host Service Commands

Check the dashboard API:

```bash
curl -fsS http://127.0.0.1:3200/api/session
launchctl print "gui/$(id -u)/com.vantacam.host"
```

Check the stream service:

```bash
launchctl print "gui/$(id -u)/com.vantacam.mediamtx"
launchctl print "gui/$(id -u)/com.vantacam.camera"
```

Force the stream off:

```bash
launchctl disable "gui/$(id -u)/com.vantacam.camera"
launchctl bootout "gui/$(id -u)/com.vantacam.camera" 2>/dev/null || true
launchctl disable "gui/$(id -u)/com.vantacam.mediamtx"
launchctl bootout "gui/$(id -u)/com.vantacam.mediamtx" 2>/dev/null || true
```

Restart the dashboard API:

```bash
launchctl bootout "gui/$(id -u)/com.vantacam.host" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.vantacam.host.plist"
launchctl kickstart -k "gui/$(id -u)/com.vantacam.host"
```

## Useful Diagnostic Bundle

Run this when you need a broad picture:

```bash
cd ~/camera-stream-pi
./pi/diagnose-pi.sh
./pi/health-check.sh
sudo systemctl status camera-dashboard --no-pager
sudo systemctl status mediamtx --no-pager
sudo journalctl -u camera-dashboard -n 80 --no-pager
sudo journalctl -u mediamtx -n 80 --no-pager
```

By default `diagnose-pi.sh` redacts IP-style values. If you are making private
operator notes for yourself, you can opt out:

```bash
REDACT=no ./pi/diagnose-pi.sh
```

Do not paste unredacted output into a public issue or public repo.
