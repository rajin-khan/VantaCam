#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const { spawn } = require('child_process');

loadEnv(path.join(__dirname, '.env'));

const config = {
  host: process.env.HOST || '127.0.0.1',
  port: Number(process.env.PORT || 3100),
  streamHost: process.env.STREAM_HOST || '127.0.0.1',
  publicStreamHost: process.env.PUBLIC_STREAM_HOST || process.env.STREAM_HOST || '127.0.0.1',
  streamPath: process.env.STREAM_PATH || 'cam',
  publicWebrtcUrl: process.env.PUBLIC_WEBRTC_URL || '',
  remoteDashboardUrl: normalizeRemoteUrl(process.env.REMOTE_DASHBOARD_URL || ''),
  rewindEnabled: parseBoolean(process.env.REWIND_ENABLED || 'false'),
  rewindDir: process.env.REWIND_DIR || '/run/vantacam-rewind',
  rewindMinutes: Number(process.env.REWIND_MINUTES || 30),
  rewindMaxMb: Number(process.env.REWIND_MAX_MB || 512),
  rewindService: process.env.REWIND_SERVICE || 'vantacam-rewind',
  rewindTokenSeconds: Number(process.env.REWIND_TOKEN_SECONDS || 900),
  appPasswordHash: requiredEnv('APP_PASSWORD_SHA256'),
  controlPasswordHash: requiredEnv('CONTROL_PASSWORD_SHA256'),
  sessionSecret: requiredEnv('SESSION_SECRET'),
  cookieSecure: process.env.COOKIE_SECURE || 'auto',
  cookieSameSite: process.env.COOKIE_SAMESITE || 'Lax',
  corsOrigins: parseCorsOrigins(process.env.CORS_ORIGIN || ''),
};

const publicDir = path.join(__dirname, 'public');
const sessionMaxAgeSeconds = 60 * 60 * 12;

const mimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.m3u8': 'application/vnd.apple.mpegurl',
  '.ts': 'video/mp2t',
  '.mp4': 'video/mp4',
};

const server = http.createServer(async (req, res) => {
  try {
    if (handleCors(req, res)) return;

    if (req.url === '/api/login' && req.method === 'POST') {
      await handleLogin(req, res);
      return;
    }

    if (req.url === '/api/logout' && req.method === 'POST') {
      clearSession(req, res);
      sendJson(res, 200, { ok: true });
      return;
    }

    if (req.url === '/api/session' && req.method === 'GET') {
      sendJson(res, 200, { authenticated: Boolean(readSession(req)) });
      return;
    }

    if (req.url === '/api/config.js' && req.method === 'GET') {
      sendConfigJs(res);
      return;
    }

    if (req.url === '/api/status' && req.method === 'GET') {
      if (requireSession(req, res)) {
        config.remoteDashboardUrl
          ? await forwardToRemoteDashboard(req, res, 'GET', '/api/status')
          : await handleStatus(res);
      }
      return;
    }

    if (req.url === '/api/control' && req.method === 'POST') {
      if (requireSession(req, res)) {
        config.remoteDashboardUrl
          ? await forwardToRemoteDashboard(req, res, 'POST', '/api/control')
          : await handleControl(req, res);
      }
      return;
    }

    if (req.url === '/api/rewind/status' && req.method === 'GET') {
      if (requireSession(req, res)) {
        config.remoteDashboardUrl
          ? await forwardToRemoteDashboard(req, res, 'GET', '/api/rewind/status')
          : await handleRewindStatus(res);
      }
      return;
    }

    if (req.url.startsWith('/stream/') && req.method === 'GET') {
      if (requireSession(req, res)) {
        config.remoteDashboardUrl
          ? await forwardToRemoteDashboard(req, res, 'GET', req.url)
          : proxyHls(req, res);
      }
      return;
    }

    if (req.url.startsWith('/rewind/') && req.method === 'GET') {
      if (config.remoteDashboardUrl) {
        await forwardToRemoteDashboard(req, res, 'GET', req.url);
      } else if (requireRewindAccess(req, res)) {
        await serveRewind(req, res);
      }
      return;
    }

    if (req.url === '/' || req.url === '/index.html') {
      serveFile(res, path.join(publicDir, 'index.html'));
      return;
    }

    if (req.url.startsWith('/assets/')) {
      serveFile(res, path.join(publicDir, req.url));
      return;
    }

    sendText(res, 404, 'Not found');
  } catch (error) {
    console.error(error);
    sendJson(res, 500, { error: 'internal_error' });
  }
});

server.listen(config.port, config.host, () => {
  console.log(`camera dashboard listening on http://${config.host}:${config.port}`);
});

function loadEnv(filePath) {
  if (!fs.existsSync(filePath)) return;
  const lines = fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const match = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) continue;
    const value = match[2].replace(/^"|"$/g, '');
    if (process.env[match[1]] === undefined) {
      process.env[match[1]] = value;
    }
  }
}

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing required environment variable: ${name}`);
    process.exit(1);
  }
  return value;
}

function normalizeRemoteUrl(value) {
  return value ? value.replace(/\/+$/, '') : '';
}

function parseCorsOrigins(value) {
  return value
    .split(',')
    .map(origin => normalizeRemoteUrl(origin.trim()))
    .filter(Boolean);
}

function parseBoolean(value) {
  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase());
}

async function handleLogin(req, res) {
  const body = await readJson(req);
  const password = String(body.password || '');
  if (!verifyPassword(password, config.appPasswordHash)) {
    sendJson(res, 401, { error: 'invalid_password' });
    return;
  }

  const sessionToken = setSession(req, res);
  sendJson(res, 200, { ok: true, sessionToken, expiresIn: sessionMaxAgeSeconds });
}

async function handleStatus(res) {
  const active = await runCommand('systemctl', ['is-active', 'mediamtx'], { allowFailure: true });
  const enabled = await runCommand('systemctl', ['is-enabled', 'mediamtx'], { allowFailure: true });
  const ports = await runShell("ss -lntup 2>/dev/null | grep -E '(:8888|:8889|:8189)' || true");
  const rewind = await rewindStatus();

  sendJson(res, 200, {
    active: active.stdout.trim() || 'unknown',
    enabled: enabled.stdout.trim() || 'unknown',
    streamPath: config.streamPath,
    webrtcUrl: config.publicWebrtcUrl || `http://${config.publicStreamHost}:8889/${config.streamPath}/`,
    hlsUrl: `/stream/index.m3u8`,
    rawHlsUrl: `http://${config.streamHost}:8888/${config.streamPath}/index.m3u8`,
    ports: ports.stdout.trim(),
    rewind,
    checkedAt: new Date().toISOString(),
  });
}

async function handleRewindStatus(res) {
  sendJson(res, 200, await rewindStatus());
}

async function handleControl(req, res) {
  const body = await readJson(req);
  const action = String(body.action || '');
  const controlPassword = String(body.controlPassword || '');

  if (action !== 'on' && action !== 'off') {
    sendJson(res, 400, { error: 'invalid_action' });
    return;
  }

  if (!verifyPassword(controlPassword, config.controlPasswordHash)) {
    sendJson(res, 401, { error: 'invalid_control_password' });
    return;
  }

  let result;
  if (action === 'on') {
    if (config.rewindEnabled) {
      await runCommand('sudo', ['systemctl', 'stop', config.rewindService], { allowFailure: true, timeoutMs: 12000 });
      await clearRewindBuffer();
    }
    result = await runCommand('sudo', ['systemctl', 'enable', '--now', 'mediamtx'], { allowFailure: true, timeoutMs: 12000 });
    if (result.code === 0 && config.rewindEnabled) {
      await runCommand('sudo', ['systemctl', 'start', config.rewindService], { allowFailure: true, timeoutMs: 12000 });
    }
  } else {
    if (config.rewindEnabled) {
      await runCommand('sudo', ['systemctl', 'stop', config.rewindService], { allowFailure: true, timeoutMs: 12000 });
    }
    result = await runCommand('sudo', ['systemctl', 'disable', '--now', 'mediamtx'], { allowFailure: true, timeoutMs: 12000 });
  }

  if (result.code !== 0) {
    sendJson(res, 500, {
      error: 'control_failed',
      detail: (result.stderr || result.stdout || '').trim(),
    });
    return;
  }

  await handleStatus(res);
}

async function rewindStatus() {
  const playlistPath = path.join(config.rewindDir, 'index.m3u8');
  const active = config.rewindEnabled
    ? await runCommand('systemctl', ['is-active', config.rewindService], { allowFailure: true })
    : { stdout: 'disabled' };
  const stats = await readRewindStats(playlistPath);
  const token = stats.available ? makeRewindToken() : '';

  return {
    enabled: config.rewindEnabled,
    active: active.stdout.trim() || 'unknown',
    available: stats.available,
    durationSeconds: stats.durationSeconds,
    segmentCount: stats.segmentCount,
    sizeBytes: stats.sizeBytes,
    maxMinutes: config.rewindMinutes,
    maxMb: config.rewindMaxMb,
    playlistPath: stats.available ? `/rewind/index.m3u8?token=${encodeURIComponent(token)}` : '',
    checkedAt: new Date().toISOString(),
  };
}

async function readRewindStats(playlistPath) {
  const stats = {
    available: false,
    durationSeconds: 0,
    segmentCount: 0,
    sizeBytes: 0,
  };

  let playlist = '';
  try {
    playlist = await fs.promises.readFile(playlistPath, 'utf8');
  } catch {
    return stats;
  }

  stats.durationSeconds = playlist
    .split(/\r?\n/)
    .filter(line => line.startsWith('#EXTINF:'))
    .reduce((total, line) => total + Number(line.replace('#EXTINF:', '').replace(',', '') || 0), 0);

  const names = playlist
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line && !line.startsWith('#') && isSafeRewindName(line));

  stats.segmentCount = names.length;
  for (const name of new Set(['index.m3u8', ...names])) {
    try {
      stats.sizeBytes += (await fs.promises.stat(path.join(config.rewindDir, name))).size;
    } catch {
      // A segment may rotate out while status is being calculated.
    }
  }
  stats.available = names.length > 0;
  return stats;
}

async function clearRewindBuffer() {
  if (!config.rewindDir || !path.isAbsolute(config.rewindDir)) return;
  try {
    await fs.promises.rm(config.rewindDir, { recursive: true, force: true });
    await fs.promises.mkdir(config.rewindDir, { recursive: true, mode: 0o750 });
  } catch {
    // The recorder service can recreate the directory; failure should not block live view.
  }
}

async function serveRewind(req, res) {
  const requestUrl = new URL(req.url, 'http://camera-dashboard.local');
  const fileName = decodeURIComponent(requestUrl.pathname.replace(/^\/rewind\/?/, ''));
  if (!isSafeRewindName(fileName)) {
    sendText(res, 400, 'Invalid rewind path');
    return;
  }

  const filePath = path.resolve(config.rewindDir, fileName);
  if (!filePath.startsWith(path.resolve(config.rewindDir))) {
    sendText(res, 403, 'Forbidden');
    return;
  }

  if (fileName === 'index.m3u8') {
    await serveRewindPlaylist(req, res, filePath);
    return;
  }

  serveFileWithMime(res, filePath, mimeTypes[path.extname(filePath)] || 'video/mp2t');
}

async function serveRewindPlaylist(req, res, filePath) {
  let playlist = '';
  try {
    playlist = await fs.promises.readFile(filePath, 'utf8');
  } catch {
    sendText(res, 404, 'Rewind buffer not available');
    return;
  }

  const requestUrl = new URL(req.url, 'http://camera-dashboard.local');
  const token = requestUrl.searchParams.get('token') || makeRewindToken();
  const rewritten = playlist
    .split(/\r?\n/)
    .map(line => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) return line;
      return isSafeRewindName(trimmed) ? `${trimmed}?token=${encodeURIComponent(token)}` : line;
    })
    .join('\n');

  res.writeHead(200, {
    'Content-Type': 'application/vnd.apple.mpegurl',
    'Cache-Control': 'no-store',
  });
  res.end(rewritten);
}

function serveFileWithMime(res, filePath, contentType) {
  fs.readFile(filePath, (error, data) => {
    if (error) {
      sendText(res, 404, 'Not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': contentType,
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
}

function isSafeRewindName(value) {
  return /^(index\.m3u8|segment_[0-9]{5}\.ts)$/.test(value);
}

function makeRewindToken() {
  const payload = Buffer.from(JSON.stringify({
    exp: Math.floor(Date.now() / 1000) + config.rewindTokenSeconds,
    scope: 'rewind',
  })).toString('base64url');
  return `${payload}.${sign(payload)}`;
}

function verifyRewindToken(token) {
  const [payload, signature] = String(token || '').split('.');
  if (!payload || !signature || !safeEqual(signature, sign(payload))) return false;
  try {
    const parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    return parsed.scope === 'rewind' && parsed.exp >= Math.floor(Date.now() / 1000);
  } catch {
    return false;
  }
}

function requireRewindAccess(req, res) {
  const requestUrl = new URL(req.url, 'http://camera-dashboard.local');
  if (verifyRewindToken(requestUrl.searchParams.get('token'))) return true;
  return requireSession(req, res);
}

function proxyHls(req, res) {
  const requestUrl = new URL(req.url, 'http://camera-dashboard.local');
  const suffix = decodeURIComponent(requestUrl.pathname.replace(/^\/stream\/?/, ''));
  if (!suffix || suffix.includes('..') || suffix.startsWith('/')) {
    sendText(res, 400, 'Invalid stream path');
    return;
  }

  fetchHlsUpstream(res, `/${config.streamPath}/${suffix}${requestUrl.search}`, 0, '');
}

async function forwardToRemoteDashboard(req, res, method, remotePath) {
  const body = method === 'POST' ? JSON.stringify(await readJson(req)) : null;
  const remoteUrl = new URL(remotePath, config.remoteDashboardUrl);
  const client = remoteUrl.protocol === 'https:' ? https : http;
  const remoteReq = client.request({
    hostname: remoteUrl.hostname,
    port: remoteUrl.port || (remoteUrl.protocol === 'https:' ? 443 : 80),
    path: `${remoteUrl.pathname}${remoteUrl.search}`,
    method,
    timeout: 12000,
    headers: {
      Cookie: req.headers.cookie || '',
      ...(body ? {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      } : {}),
    },
  }, remoteRes => {
    res.writeHead(remoteRes.statusCode || 502, {
      'Content-Type': remoteRes.headers['content-type'] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    remoteRes.pipe(res);
  });

  remoteReq.on('timeout', () => {
    remoteReq.destroy();
    sendText(res, 504, 'Remote dashboard timed out');
  });

  remoteReq.on('error', () => {
    if (!res.headersSent) sendText(res, 502, 'Remote dashboard unavailable');
  });

  if (body) remoteReq.write(body);
  remoteReq.end();
}

function fetchHlsUpstream(res, upstreamPath, redirectCount, cookieHeader) {
  const upstream = http.request({
    hostname: config.streamHost,
    port: 8888,
    path: upstreamPath,
    method: 'GET',
    timeout: 12000,
    headers: cookieHeader ? { Cookie: cookieHeader } : {},
  }, upstreamRes => {
    if (upstreamRes.statusCode >= 300 && upstreamRes.statusCode < 400 && upstreamRes.headers.location) {
      if (redirectCount >= 3) {
        sendText(res, 502, 'Too many stream redirects');
        upstreamRes.resume();
        return;
      }

      const location = new URL(upstreamRes.headers.location, `http://${config.streamHost}:8888`);
      if (!location.pathname.startsWith(`/${config.streamPath}/`)) {
        sendText(res, 502, 'Invalid stream redirect');
        upstreamRes.resume();
        return;
      }

      const cookie = normalizeSetCookie(upstreamRes.headers['set-cookie']);
      upstreamRes.resume();
      fetchHlsUpstream(res, `${location.pathname}${location.search}`, redirectCount + 1, cookie || cookieHeader);
      return;
    }

    res.writeHead(upstreamRes.statusCode || 502, {
      'Content-Type': upstreamRes.headers['content-type'] || mimeTypes[path.extname(new URL(upstreamPath, 'http://stream.local').pathname)] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    upstreamRes.pipe(res);
  });

  upstream.on('timeout', () => {
    upstream.destroy();
    sendText(res, 504, 'Stream timed out');
  });

  upstream.on('error', () => {
    if (!res.headersSent) sendText(res, 502, 'Stream unavailable');
  });

  upstream.end();
}

function normalizeSetCookie(setCookie) {
  if (!setCookie) return '';
  const values = Array.isArray(setCookie) ? setCookie : [setCookie];
  return values
    .map(value => value.split(';')[0])
    .filter(Boolean)
    .join('; ');
}

function setSession(req, res) {
  const payload = Buffer.from(JSON.stringify({
    exp: Math.floor(Date.now() / 1000) + sessionMaxAgeSeconds,
    nonce: crypto.randomBytes(16).toString('hex'),
  })).toString('base64url');
  const signature = sign(payload);
  const token = `${payload}.${signature}`;
  const secure = shouldUseSecureCookie(req) ? '; Secure' : '';
  res.setHeader('Set-Cookie', `camera_session=${token}; HttpOnly; SameSite=${config.cookieSameSite}${secure}; Path=/; Max-Age=${sessionMaxAgeSeconds}`);
  return token;
}

function clearSession(req, res) {
  const secure = shouldUseSecureCookie(req) ? '; Secure' : '';
  res.setHeader('Set-Cookie', `camera_session=; HttpOnly; SameSite=${config.cookieSameSite}${secure}; Path=/; Max-Age=0`);
}

function readSession(req) {
  const cookies = parseCookies(req.headers.cookie || '');
  const token = cookies.camera_session || readBearerToken(req);
  if (!token) return null;

  const [payload, signature] = token.split('.');
  if (!payload || !signature || !safeEqual(signature, sign(payload))) return null;

  try {
    const parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    if (!parsed.exp || parsed.exp < Math.floor(Date.now() / 1000)) return null;
    return parsed;
  } catch {
    return null;
  }
}

function readBearerToken(req) {
  const value = String(req.headers.authorization || '');
  const match = value.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : '';
}

function requireSession(req, res) {
  if (readSession(req)) return true;
  sendJson(res, 401, { error: 'unauthorized' });
  return false;
}

function sign(payload) {
  return crypto.createHmac('sha256', config.sessionSecret).update(payload).digest('base64url');
}

function verifyPassword(password, expectedHash) {
  const actual = crypto.createHash('sha256').update(password).digest('hex');
  return safeEqual(actual, expectedHash);
}

function safeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function parseCookies(header) {
  const cookies = {};
  for (const part of header.split(';')) {
    const index = part.indexOf('=');
    if (index === -1) continue;
    cookies[part.slice(0, index).trim()] = decodeURIComponent(part.slice(index + 1).trim());
  }
  return cookies;
}

function shouldUseSecureCookie(req) {
  if (config.cookieSecure === 'true') return true;
  if (config.cookieSecure === 'false') return false;
  return req.headers['x-forwarded-proto'] === 'https';
}

function handleCors(req, res) {
  const origin = req.headers.origin || '';
  const allowed = config.corsOrigins.includes(origin);
  if (allowed) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Credentials', 'true');
    res.setHeader('Vary', 'Origin');
  }

  if (req.method !== 'OPTIONS') return false;

  if (!allowed) {
    sendText(res, 403, 'CORS origin not allowed');
    return true;
  }

  res.writeHead(204, {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '600',
    'Vary': 'Origin',
  });
  res.end();
  return true;
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 4096) {
        req.destroy();
        reject(new Error('request body too large'));
      }
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (error) {
        reject(error);
      }
    });
  });
}

function sendJson(res, status, data) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(JSON.stringify(data));
}

function sendText(res, status, text) {
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(text);
}

function sendConfigJs(res) {
  const apiBase = process.env.PUBLIC_DASHBOARD_API_BASE || '';
  res.writeHead(200, {
    'Content-Type': 'text/javascript; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(`window.CAMERA_CONFIG = ${JSON.stringify({ apiBase })};\n`);
}

function serveFile(res, filePath) {
  const resolved = path.resolve(filePath);
  if (!resolved.startsWith(publicDir)) {
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
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
}

function runCommand(command, args, options = {}) {
  return new Promise(resolve => {
    const child = spawn(command, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: options.timeoutMs || 5000,
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', error => {
      resolve({ code: 127, stdout, stderr: error.message });
    });
    child.on('close', code => {
      resolve({ code, stdout, stderr });
    });
  });
}

function runShell(script) {
  return runCommand('sh', ['-c', script], { allowFailure: true });
}
