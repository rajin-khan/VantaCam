# VantaCam Mac Host

This folder is a separate add-on for turning a Mac into a VantaCam camera host.
It does not modify the Raspberry Pi implementation.

The Mac host uses:

- Python 3 for the private dashboard/control API.
- MediaMTX for WebRTC streaming.
- ffmpeg with AVFoundation for the Mac webcam.
- LaunchAgents for start/stop behavior.

## What Gets Installed

The installer keeps app data in normal macOS user locations:

```text
~/Library/Application Support/VantaCam/bin/
~/Library/Application Support/VantaCam/config/
~/Library/Application Support/VantaCam/logs/
~/Library/LaunchAgents/com.vantacam.host.plist
~/Library/LaunchAgents/com.vantacam.mediamtx.plist
~/Library/LaunchAgents/com.vantacam.camera.plist
~/.vantacam/bin/run-camera
```

`com.vantacam.host` is the dashboard/control API. It should stay running.
`com.vantacam.mediamtx` is the stream engine. `com.vantacam.camera` is the
ffmpeg publisher that reads the Mac camera and publishes frames into MediaMTX.
Both stream services stay disabled until you turn the stream on.

## List Cameras

```bash
./mac/install-mac.sh --list-cameras
```

## Install

Use the default AVFoundation camera:

```bash
./mac/install-mac.sh --camera 0
```

Use a named camera:

```bash
./mac/install-mac.sh --camera "FaceTime HD Camera"
```

Use a USB camera by index:

```bash
./mac/install-mac.sh --camera 1
```

The installer prints the dashboard URL, WebRTC URL, dashboard password, and
stream control password. Store those in the ignored private runbook.

Useful install options:

```bash
./mac/install-mac.sh \
  --camera 0 \
  --stream-name mac-your-private-path \
  --public-host 100.x.y.z \
  --host 0.0.0.0 \
  --port 3200 \
  --video-size 1280x720 \
  --framerate 30 \
  --pixel-format nv12 \
  --start-ready-timeout 20 \
  --bitrate 1200k
```

Use `--pixel-format uyvy422` if `nv12` does not produce frames on an older Mac
camera.

For Vercel/fleet mode, prefer private Tailscale Serve HTTPS:

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

If native Tailscale Serve does not persist on a Mac, use the Tailscale
certificate proxy fallback instead:

```bash
./mac/install-mac.sh \
  --camera 0 \
  --stream-name mac-your-private-path \
  --public-host macbook.your-tailnet.ts.net \
  --public-webrtc-url https://macbook.your-tailnet.ts.net:9444/mac-your-private-path/ \
  --host 127.0.0.1 \
  --port 3200 \
  --cors-origin https://your-fleet-site.vercel.app \
  --cookie-secure true \
  --cookie-samesite None

./mac/enable-tailscale-cert-proxy.sh
```

For local fleet preview before Vercel exists, use:

```bash
--cors-origin http://127.0.0.1:3300,http://localhost:3300
```

You can include all needed origins as a comma-separated list.

## On/Off

Open the printed dashboard URL, log in, enter the stream control password, then
use `Turn On` or `Turn Off`.

The stream starts off after install. Turning it on loads the MediaMTX LaunchAgent.
Turning it on also loads the camera publisher LaunchAgent. Turning it off
unloads and disables both stream LaunchAgents.

The API waits briefly for MediaMTX to report the stream path as ready before the
`Turn On` command returns. The default wait is 20 seconds; change it with
`--start-ready-timeout` if an older Mac needs longer.

## Service Commands

```bash
launchctl print "gui/$(id -u)/com.vantacam.host"
launchctl print "gui/$(id -u)/com.vantacam.mediamtx"
launchctl print "gui/$(id -u)/com.vantacam.camera"
```

Restart the dashboard API:

```bash
launchctl bootout "gui/$(id -u)/com.vantacam.host" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.vantacam.host.plist"
launchctl kickstart -k "gui/$(id -u)/com.vantacam.host"
```

Force the stream off:

```bash
launchctl disable "gui/$(id -u)/com.vantacam.camera"
launchctl bootout "gui/$(id -u)/com.vantacam.camera" 2>/dev/null || true
launchctl disable "gui/$(id -u)/com.vantacam.mediamtx"
launchctl bootout "gui/$(id -u)/com.vantacam.mediamtx" 2>/dev/null || true
```

## Tailscale Serve HTTPS

Enable private HTTPS routes for the Mac dashboard and WebRTC page:

```bash
./mac/enable-tailscale-serve.sh
```

Expected routes:

```text
https://macbook.your-tailnet.ts.net
https://macbook.your-tailnet.ts.net:8443
```

Use those HTTPS URLs in `fleet-site` and Vercel. Do not use Tailscale Funnel.

## Tailscale Cert Proxy Fallback

Some macOS Tailscale clients can print that `tailscale serve --bg` started but
then show an empty Serve config. When that happens, use the cert proxy fallback:

```bash
./mac/enable-tailscale-cert-proxy.sh
```

It uses `tailscale cert` to issue a certificate for the Mac tailnet DNS name,
then starts two user LaunchAgents:

```text
com.vantacam.https-dashboard -> https://macbook.your-tailnet.ts.net:9443/
com.vantacam.https-webrtc    -> https://macbook.your-tailnet.ts.net:9444/
```

Use the dashboard origin as the camera `apiBase` and the WebRTC URL with the
private stream path:

```text
apiBase:   https://macbook.your-tailnet.ts.net:9443
streamUrl: https://macbook.your-tailnet.ts.net:9444/mac-your-private-path/
```

## Logs

```bash
tail -100 "$HOME/Library/Application Support/VantaCam/logs/host.err.log"
tail -100 "$HOME/Library/Application Support/VantaCam/logs/mediamtx.out.log"
tail -100 "$HOME/Library/Application Support/VantaCam/logs/ffmpeg.log"
```

Use `GET`, a browser, or the dashboard status when checking the WebRTC page.
MediaMTX can return `404` to a `HEAD` request even when the stream page works in
a browser. If status shows `pathReady: false` while MediaMTX is active, the
stream engine is up but no camera frames have been published yet. The most
useful file is `ffmpeg.log`.

## macOS Camera Permission

macOS can block camera access for command-line tools until a local privacy prompt
is approved. If the Mac is remote, use Screen Sharing or physical access and
check:

```text
System Settings -> Privacy & Security -> Camera
```

Approve the terminal/ffmpeg-related entry if macOS shows one, then turn the
stream off and on again.

Also check simple physical states:

- The MacBook lid should be open if you are using the built-in camera.
- The camera should not already be in use by FaceTime, Zoom, Chrome, or another
  app.
- If using a USB camera, try a direct USB port before blaming the stream stack.

## Direct Camera Probe

Run this on the Mac when MediaMTX is fine but no frames appear:

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

If that hangs before producing frames, the issue is below VantaCam: macOS camera
permission, camera already in use, laptop lid/lock state, or unsupported capture
mode. Try `-pixel_format uyvy422` and `-video_size 640x480` as a conservative
fallback.
