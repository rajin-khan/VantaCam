#!/usr/bin/env node
'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');

const root = __dirname;
const host = process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT || 3000);
const piApiBase = process.env.PI_API_BASE || '';
const directApi = process.env.LOCAL_DIRECT_API === 'true';

const mimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};

const server = http.createServer((req, res) => {
  if (req.url === '/api/config.js') {
    res.writeHead(200, {
      'Content-Type': 'text/javascript; charset=utf-8',
      'Cache-Control': 'no-store',
    });
    res.end(`window.CAMERA_CONFIG = ${JSON.stringify({ apiBase: directApi ? piApiBase : '' })};\n`);
    return;
  }

  if ((req.url.startsWith('/api/') || req.url.startsWith('/stream/')) && piApiBase && !directApi) {
    proxyToBackend(req, res);
    return;
  }

  const requestUrl = new URL(req.url, `http://${host}:${port}`);
  const pathname = requestUrl.pathname === '/' ? '/index.html' : requestUrl.pathname;
  const filePath = path.resolve(root, `.${pathname}`);
  if (!filePath.startsWith(root)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  fs.readFile(filePath, (error, data) => {
    if (error) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }

    res.writeHead(200, {
      'Content-Type': mimeTypes[path.extname(filePath)] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
});

server.listen(port, host, () => {
  console.log(`Vercel-site preview listening on http://${host}:${port}`);
  console.log(`PI_API_BASE=${piApiBase || '(empty)'}`);
  console.log(`API mode=${directApi ? 'direct browser calls' : 'same-origin local proxy'}`);
});

function proxyToBackend(req, res) {
  const targetBase = new URL(piApiBase);
  const client = targetBase.protocol === 'https:' ? https : http;
  const headers = { ...req.headers, host: targetBase.host };
  delete headers['accept-encoding'];

  const proxyReq = client.request({
    protocol: targetBase.protocol,
    hostname: targetBase.hostname,
    port: targetBase.port || (targetBase.protocol === 'https:' ? 443 : 80),
    method: req.method,
    path: req.url,
    headers,
    timeout: 15000,
  }, proxyRes => {
    res.writeHead(proxyRes.statusCode || 502, {
      ...proxyRes.headers,
      'cache-control': 'no-store',
    });
    proxyRes.pipe(res);
  });

  proxyReq.on('timeout', () => {
    proxyReq.destroy();
    res.writeHead(504, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Backend timed out');
  });

  proxyReq.on('error', error => {
    if (res.headersSent) return;
    res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(`Backend unavailable: ${error.message}`);
  });

  req.pipe(proxyReq);
}
