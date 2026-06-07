#!/usr/bin/env python3
import base64
import hashlib
import hmac
import http.cookies
import http.server
import json
import os
import pathlib
import secrets
import socketserver
import subprocess
import time
import urllib.parse
import urllib.request


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent


def load_env(path):
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key, value.strip().strip('"'))


load_env(SCRIPT_DIR / ".env")


HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "3200"))
STREAM_NAME = os.environ.get("STREAM_NAME", "mac-cam")
PUBLIC_WEBRTC_URL = os.environ.get("PUBLIC_WEBRTC_URL", "")
PUBLIC_STREAM_HOST = os.environ.get("PUBLIC_STREAM_HOST", HOST)
APP_PASSWORD_SHA256 = os.environ.get("APP_PASSWORD_SHA256", "")
CONTROL_PASSWORD_SHA256 = os.environ.get("CONTROL_PASSWORD_SHA256", "")
SESSION_SECRET = os.environ.get("SESSION_SECRET", "")
COOKIE_SECURE = os.environ.get("COOKIE_SECURE", "false").lower() == "true"
COOKIE_SAMESITE = os.environ.get("COOKIE_SAMESITE", "Lax")
CORS_ORIGINS = [
    item.strip().rstrip("/")
    for item in os.environ.get("CORS_ORIGIN", "").split(",")
    if item.strip()
]
START_READY_TIMEOUT_SECONDS = float(os.environ.get("START_READY_TIMEOUT_SECONDS", "20"))
MEDIA_LABEL = os.environ.get("MEDIAMTX_LABEL", "com.vantacam.mediamtx")
MEDIA_PLIST = pathlib.Path(os.environ.get(
    "MEDIAMTX_PLIST",
    str(pathlib.Path.home() / "Library/LaunchAgents/com.vantacam.mediamtx.plist"),
))
CAMERA_LABEL = os.environ.get("CAMERA_LABEL", "com.vantacam.camera")
CAMERA_PLIST = pathlib.Path(os.environ.get(
    "CAMERA_PLIST",
    str(pathlib.Path.home() / "Library/LaunchAgents/com.vantacam.camera.plist"),
))
PUBLIC_DIR = pathlib.Path(os.environ.get("PUBLIC_DIR", str(PROJECT_DIR / "web/public")))
SESSION_MAX_AGE_SECONDS = 60 * 60 * 12


MIME_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".svg": "image/svg+xml",
}


def require_env(name, value):
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")


require_env("APP_PASSWORD_SHA256", APP_PASSWORD_SHA256)
require_env("CONTROL_PASSWORD_SHA256", CONTROL_PASSWORD_SHA256)
require_env("SESSION_SECRET", SESSION_SECRET)


def hash_password(password):
    return hashlib.sha256(password.encode()).hexdigest()


def verify_password(password, expected_hash):
    return hmac.compare_digest(hash_password(password), expected_hash)


def sign(value):
    digest = hmac.new(SESSION_SECRET.encode(), value.encode(), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")


def make_session():
    payload = f"{int(time.time())}.{secrets.token_urlsafe(24)}"
    return f"{payload}.{sign(payload)}"


def verify_session(token):
    parts = token.split(".")
    if len(parts) < 3:
        return False
    payload = ".".join(parts[:-1])
    signature = parts[-1]
    if not hmac.compare_digest(sign(payload), signature):
        return False
    try:
        issued_at = int(parts[0])
    except ValueError:
        return False
    return time.time() - issued_at <= SESSION_MAX_AGE_SECONDS


def run(args, timeout=12, allow_failure=True):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        return {"code": 124, "stdout": error.stdout or "", "stderr": error.stderr or "timeout"}
    if result.returncode != 0 and not allow_failure:
        raise RuntimeError(result.stderr or result.stdout)
    return {"code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


def launch_domain():
    return f"gui/{os.getuid()}"


def launch_service_ref(label):
    return f"{launch_domain()}/{label}"


def service_active(label):
    result = run(["launchctl", "print", launch_service_ref(label)])
    return result["code"] == 0


def service_disabled(label):
    result = run(["launchctl", "print-disabled", launch_domain()])
    return f'"{label}" => true' in result["stdout"]


def service_enabled_text(label):
    return "disabled" if service_disabled(label) else "enabled"


def service_active_text(label, plist):
    if not plist.exists():
        return "missing"
    return "active" if service_active(label) else "inactive"


def start_service(label, plist):
    run(["launchctl", "enable", launch_service_ref(label)])
    if not service_active(label):
        run(["launchctl", "bootstrap", launch_domain(), str(plist)])
    run(["launchctl", "kickstart", "-k", launch_service_ref(label)])


def stop_service(label):
    run(["launchctl", "disable", launch_service_ref(label)])
    if service_active(label):
        run(["launchctl", "bootout", launch_service_ref(label)])


def service_on():
    cleanup_camera_processes()
    start_service(MEDIA_LABEL, MEDIA_PLIST)
    time.sleep(1)
    start_service(CAMERA_LABEL, CAMERA_PLIST)
    wait_for_path_ready(START_READY_TIMEOUT_SECONDS)


def service_off():
    stop_service(CAMERA_LABEL)
    cleanup_camera_processes()
    stop_service(MEDIA_LABEL)


def cleanup_camera_processes():
    run(["pkill", "-f", str(pathlib.Path.home() / ".vantacam/bin/run-camera")])
    run(["pkill", "-f", str(pathlib.Path.home() / ".vantacam/bin/ffmpeg")])


def status_payload():
    webrtc_url = PUBLIC_WEBRTC_URL or f"http://{PUBLIC_STREAM_HOST}:8889/{STREAM_NAME}/"
    media_active = service_active_text(MEDIA_LABEL, MEDIA_PLIST)
    camera_active = service_active_text(CAMERA_LABEL, CAMERA_PLIST)
    media_enabled = service_enabled_text(MEDIA_LABEL)
    camera_enabled = service_enabled_text(CAMERA_LABEL)
    path_ready = mediamtx_path_ready() if media_active == "active" else False
    active = "active" if media_active == "active" and camera_active == "active" and path_ready else "inactive"
    enabled = "enabled" if media_enabled == "enabled" and camera_enabled == "enabled" else "disabled"
    return {
        "active": active,
        "enabled": enabled,
        "mediaActive": media_active,
        "cameraActive": camera_active,
        "mediaEnabled": media_enabled,
        "cameraEnabled": camera_enabled,
        "pathReady": path_ready,
        "streamPath": STREAM_NAME,
        "webrtcUrl": webrtc_url,
        "hlsUrl": "",
        "rawHlsUrl": "",
        "ports": "",
        "checkedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def mediamtx_path_ready():
    try:
        with urllib.request.urlopen("http://127.0.0.1:9997/v3/paths/list", timeout=2) as response:
            payload = json.loads(response.read().decode())
    except Exception:
        return False
    for item in payload.get("items", []):
        if item.get("name") == STREAM_NAME:
            return bool(item.get("ready"))
    return False


def wait_for_path_ready(timeout_seconds):
    deadline = time.time() + max(0, timeout_seconds)
    while time.time() < deadline:
        if mediamtx_path_ready():
            return True
        time.sleep(0.5)
    return mediamtx_path_ready()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        if not self.origin_allowed():
            self.send_text(403, "CORS origin not allowed")
            return
        self.send_response(204)
        self.send_common_headers()
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Max-Age", "600")
        self.end_headers()

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/session":
            self.send_json(200, {"authenticated": bool(self.read_session())})
            return
        if path == "/api/config.js":
            self.send_text(200, "window.CAMERA_CONFIG = { apiBase: '' };\n", "text/javascript; charset=utf-8")
            return
        if path == "/api/status":
            if self.require_session():
                self.send_json(200, status_payload())
            return
        if path == "/" or path == "/index.html":
            self.serve_file(PUBLIC_DIR / "index.html")
            return
        if path.startswith("/assets/"):
            self.serve_file(PUBLIC_DIR / path.removeprefix("/"))
            return
        self.send_text(404, "Not found")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/login":
            body = self.read_json()
            if verify_password(str(body.get("password", "")), APP_PASSWORD_SHA256):
                cookie = http.cookies.SimpleCookie()
                cookie["camera_session"] = make_session()
                cookie["camera_session"]["path"] = "/"
                cookie["camera_session"]["max-age"] = str(SESSION_MAX_AGE_SECONDS)
                cookie["camera_session"]["samesite"] = COOKIE_SAMESITE
                if COOKIE_SECURE:
                    cookie["camera_session"]["secure"] = True
                cookie["camera_session"]["httponly"] = True
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_common_headers()
                self.send_header("Set-Cookie", cookie.output(header="").strip())
                self.end_headers()
                self.wfile.write(json.dumps({"ok": True}).encode())
            else:
                self.send_json(401, {"error": "invalid_password"})
            return
        if path == "/api/logout":
            secure = "; Secure" if COOKIE_SECURE else ""
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_common_headers()
            self.send_header("Set-Cookie", f"camera_session=; Path=/; Max-Age=0; SameSite={COOKIE_SAMESITE}{secure}")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True}).encode())
            return
        if path == "/api/control":
            if not self.require_session():
                return
            body = self.read_json()
            action = str(body.get("action", ""))
            control_password = str(body.get("controlPassword", ""))
            if action not in ("on", "off"):
                self.send_json(400, {"error": "invalid_action"})
                return
            if not verify_password(control_password, CONTROL_PASSWORD_SHA256):
                self.send_json(401, {"error": "invalid_control_password"})
                return
            if action == "on":
                service_on()
            else:
                service_off()
            time.sleep(1)
            self.send_json(200, status_payload())
            return
        self.send_text(404, "Not found")

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode())
        except json.JSONDecodeError:
            return {}

    def read_session(self):
        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        morsel = cookie.get("camera_session")
        if not morsel:
            return None
        return morsel.value if verify_session(morsel.value) else None

    def require_session(self):
        if self.read_session():
            return True
        self.send_json(401, {"error": "unauthorized"})
        return False

    def serve_file(self, file_path):
        safe_path = file_path.resolve()
        if not str(safe_path).startswith(str(PUBLIC_DIR.resolve())) or not safe_path.exists():
            self.send_text(404, "Not found")
            return
        content_type = MIME_TYPES.get(safe_path.suffix, "application/octet-stream")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_common_headers()
        self.send_header("Cache-Control", "no-store" if safe_path.name == "index.html" else "public, max-age=3600")
        self.end_headers()
        self.wfile.write(safe_path.read_bytes())

    def send_json(self, status, payload):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_common_headers()
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def send_text(self, status, text, content_type="text/plain; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_common_headers()
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(text.encode())

    def send_common_headers(self):
        origin = (self.headers.get("Origin") or "").rstrip("/")
        if origin and self.origin_allowed(origin):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Credentials", "true")
            self.send_header("Vary", "Origin")

    def origin_allowed(self, origin=None):
        origin = (origin or self.headers.get("Origin") or "").rstrip("/")
        if not origin:
            return True
        return "*" in CORS_ORIGINS or origin in CORS_ORIGINS

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}")


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    with ReusableTCPServer((HOST, PORT), Handler) as server:
        print(f"VantaCam Mac host listening on http://{HOST}:{PORT}")
        server.serve_forever()
