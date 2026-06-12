#!/usr/bin/env node
'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');

const root = __dirname;
const port = Number(process.env.PORT || 3300);
const host = process.env.HOST || '127.0.0.1';
const cameraProxyTimeoutMs = Number(process.env.CAMERA_PROXY_TIMEOUT_MS || 30000);
const cameras = loadCameras();
const cameraById = new Map(cameras.map(camera => [camera.id, camera]));

const mimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
};

const server = http.createServer((req, res) => {
  if (req.url === '/api/config.js') {
    sendConfig(res);
    return;
  }

  if (req.url.startsWith('/camera/')) {
    proxyCamera(req, res);
    return;
  }

  const requestPath = req.url === '/' ? '/index.html' : new URL(req.url, `http://${host}:${port}`).pathname;
  serveFile(res, path.join(root, requestPath));
});

server.listen(port, host, () => {
  console.log(`VantaCam fleet preview listening on http://${host}:${port}`);
  console.log(`Configured cameras: ${cameras.length}`);
});

function loadCameras() {
  if (process.env.FLEET_CAMERAS_JSON) {
    return parseCameras(process.env.FLEET_CAMERAS_JSON);
  }

  const localPath = path.join(root, 'cameras.local.json');
  if (fs.existsSync(localPath)) {
    return parseCameras(fs.readFileSync(localPath, 'utf8'));
  }

  return [];
}

function parseCameras(value) {
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch {
    return [];
  }

  if (!Array.isArray(parsed)) return [];
  return parsed
    .map((camera, index) => ({
      id: cleanId(camera.id || `camera-${index + 1}`),
      name: String(camera.name || `Camera ${index + 1}`),
      kind: String(camera.kind || 'Tailnet camera'),
      apiBase: normalizeUrl(camera.apiBase || ''),
      streamUrl: normalizeUrl(camera.streamUrl || ''),
    }))
    .filter(camera => camera.apiBase);
}

function cleanId(value) {
  return String(value).replace(/[^a-z0-9_-]/gi, '-');
}

function normalizeUrl(value) {
  return String(value || '').trim().replace(/\/+$/, '');
}

function sendConfig(res) {
  const browserCameras = cameras.map(camera => ({
    ...camera,
    apiBase: `/camera/${encodeURIComponent(camera.id)}`,
  }));
  res.writeHead(200, {
    'Content-Type': 'text/javascript; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(`window.VANTACAM_FLEET_CONFIG = ${JSON.stringify({ cameras: browserCameras })};\n`);
}

function proxyCamera(req, res) {
  const requestUrl = new URL(req.url, `http://${host}:${port}`);
  const match = requestUrl.pathname.match(/^\/camera\/([^/]+)(\/.*)$/);
  if (!match) {
    sendText(res, 404, 'Camera route not found');
    return;
  }

  const camera = cameraById.get(decodeURIComponent(match[1]));
  if (!camera) {
    sendText(res, 404, 'Camera not configured');
    return;
  }

  const upstreamBase = new URL(camera.apiBase);
  const upstreamPath = `${match[2]}${requestUrl.search}`;
  const bodyChunks = [];
  req.on('data', chunk => bodyChunks.push(chunk));
  req.on('end', () => {
    const body = Buffer.concat(bodyChunks);
    const client = upstreamBase.protocol === 'https:' ? https : http;
    const upstreamReq = client.request({
      hostname: upstreamBase.hostname,
      port: upstreamBase.port || (upstreamBase.protocol === 'https:' ? 443 : 80),
      path: upstreamPath,
      method: req.method,
      timeout: cameraProxyTimeoutMs,
      rejectUnauthorized: false,
      headers: {
        ...(req.headers['content-type'] ? { 'Content-Type': req.headers['content-type'] } : {}),
        ...(req.headers.authorization ? { Authorization: req.headers.authorization } : {}),
        ...(body.length ? { 'Content-Length': body.length } : {}),
        ...(req.headers.cookie ? { Cookie: req.headers.cookie } : {}),
      },
    }, upstreamRes => {
      const headers = {
        'Content-Type': upstreamRes.headers['content-type'] || 'application/octet-stream',
        'Cache-Control': 'no-store',
      };
      const setCookie = rewriteCookies(upstreamRes.headers['set-cookie'], camera.id);
      if (setCookie.length) headers['Set-Cookie'] = setCookie;
      res.writeHead(upstreamRes.statusCode || 502, headers);
      upstreamRes.pipe(res);
    });

    upstreamReq.on('timeout', () => {
      upstreamReq.destroy();
      if (!res.headersSent) sendJson(res, 504, { error: 'camera_api_timeout' });
    });
    upstreamReq.on('error', error => {
      if (!res.headersSent) sendJson(res, 502, { error: 'camera_api_unavailable', detail: error.message });
    });
    if (body.length) upstreamReq.write(body);
    upstreamReq.end();
  });
}

function rewriteCookies(setCookie, cameraId) {
  if (!setCookie) return [];
  const values = Array.isArray(setCookie) ? setCookie : [setCookie];
  return values.map(cookie => {
    const withoutDomain = cookie.replace(/;\s*Domain=[^;]*/ig, '');
    if (/;\s*Path=/i.test(withoutDomain)) {
      return withoutDomain.replace(/;\s*Path=[^;]*/i, `; Path=/camera/${encodeURIComponent(cameraId)}`);
    }
    return `${withoutDomain}; Path=/camera/${encodeURIComponent(cameraId)}`;
  });
}

function serveFile(res, filePath) {
  const resolved = path.resolve(filePath);
  if (!resolved.startsWith(root)) {
    sendText(res, 403, 'Forbidden');
    return;
  }

  fs.readFile(resolved, (error, data) => {
    if (error) {
      sendText(res, 404, 'Not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': mimeTypes[path.extname(resolved)] || 'application/octet-stream',
      'Cache-Control': resolved.endsWith('index.html') ? 'no-store' : 'public, max-age=3600',
    });
    res.end(data);
  });
}

function sendText(res, status, text) {
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(text);
}

function sendJson(res, status, payload) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(JSON.stringify(payload));
}
