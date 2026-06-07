#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const options = parseArgs(args);
const source = loadSource(options);
const cameras = parseJsonArray(source.value, source.label);
const result = validateCameras(cameras, options);

for (const line of result.lines) {
  console.log(line);
}

if (result.errors.length) {
  console.error('\nErrors:');
  for (const error of result.errors) console.error(`- ${error}`);
}

if (result.warnings.length) {
  console.error('\nWarnings:');
  for (const warning of result.warnings) console.error(`- ${warning}`);
}

process.exit(result.errors.length ? 1 : 0);

function parseArgs(values) {
  const parsed = {
    file: '',
    json: '',
    production: false,
  };

  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (value === '--production' || value === '--prod') {
      parsed.production = true;
    } else if (value === '--file') {
      parsed.file = values[index + 1] || '';
      index += 1;
    } else if (value === '--json') {
      parsed.json = values[index + 1] || '';
      index += 1;
    } else if (value === '-h' || value === '--help') {
      printHelp();
      process.exit(0);
    } else {
      console.error(`Unknown option: ${value}`);
      printHelp();
      process.exit(1);
    }
  }

  return parsed;
}

function printHelp() {
  console.log(`Usage: node fleet-site/verify-config.js [options]

Options:
  --file PATH        Read camera JSON from a file.
  --json JSON        Read camera JSON from an argument.
  --production       Require HTTPS camera URLs for Vercel deployment.
  -h, --help         Show this help.

Default source order:
  1. FLEET_CAMERAS_JSON
  2. fleet-site/cameras.local.json
  3. fleet-site/cameras.example.json
`);
}

function loadSource(options) {
  if (options.json) {
    return { label: '--json', value: options.json };
  }

  if (options.file) {
    return { label: options.file, value: fs.readFileSync(options.file, 'utf8') };
  }

  if (process.env.FLEET_CAMERAS_JSON) {
    return { label: 'FLEET_CAMERAS_JSON', value: process.env.FLEET_CAMERAS_JSON };
  }

  const localPath = path.join(__dirname, 'cameras.local.json');
  if (fs.existsSync(localPath)) {
    return { label: localPath, value: fs.readFileSync(localPath, 'utf8') };
  }

  const examplePath = path.join(__dirname, 'cameras.example.json');
  return { label: examplePath, value: fs.readFileSync(examplePath, 'utf8') };
}

function parseJsonArray(value, label) {
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch (error) {
    console.error(`Could not parse ${label}: ${error.message}`);
    process.exit(1);
  }

  if (!Array.isArray(parsed)) {
    console.error(`${label} must be a JSON array.`);
    process.exit(1);
  }

  return parsed;
}

function validateCameras(cameras, options) {
  const errors = [];
  const warnings = [];
  const lines = [`Checking ${cameras.length} configured camera${cameras.length === 1 ? '' : 's'}...`];
  const ids = new Set();

  if (!cameras.length) {
    errors.push('At least one camera must be configured.');
  }

  cameras.forEach((camera, index) => {
    const label = cameraLabel(camera, index);
    const id = String(camera.id || '').trim();
    const apiBase = String(camera.apiBase || '').trim();
    const streamUrl = String(camera.streamUrl || '').trim();

    if (!id) {
      errors.push(`${label}: missing id.`);
    } else if (!/^[A-Za-z0-9_-]+$/.test(id)) {
      errors.push(`${label}: id must contain only letters, numbers, underscores, or dashes.`);
    } else if (ids.has(id)) {
      errors.push(`${label}: duplicate id "${id}".`);
    } else {
      ids.add(id);
    }

    if (!apiBase) {
      errors.push(`${label}: missing apiBase.`);
    } else {
      validateUrl(`${label}: apiBase`, apiBase, options, errors, warnings);
      if (/\/api\/?$/.test(apiBase)) {
        warnings.push(`${label}: apiBase should be the host origin, not a /api path.`);
      }
    }

    if (streamUrl) {
      validateUrl(`${label}: streamUrl`, streamUrl, options, errors, warnings);
    } else {
      warnings.push(`${label}: streamUrl is empty; the UI will rely on /api/status webrtcUrl.`);
    }

    lines.push(`ok: ${id || label} (${String(camera.name || 'unnamed')})`);
  });

  if (options.production) {
    lines.push('production mode: HTTPS camera URLs required');
  } else {
    lines.push('local mode: HTTP tailnet URLs are allowed for preview');
  }

  return { errors, warnings, lines };
}

function validateUrl(label, value, options, errors, warnings) {
  let url;
  try {
    url = new URL(value);
  } catch {
    errors.push(`${label} is not a valid URL.`);
    return;
  }

  if (!['http:', 'https:'].includes(url.protocol)) {
    errors.push(`${label} must use http or https.`);
  }

  if (options.production && url.protocol !== 'https:') {
    errors.push(`${label} must use https in production/Vercel mode.`);
  }

  if (options.production && isLocalHost(url.hostname)) {
    errors.push(`${label} cannot use localhost or loopback in production/Vercel mode.`);
  }

  if (url.hostname.includes('funnel')) {
    warnings.push(`${label} looks like Funnel; prefer private Tailscale Serve for this project.`);
  }
}

function isLocalHost(hostname) {
  return hostname === 'localhost'
    || hostname === '127.0.0.1'
    || hostname === '::1'
    || hostname.startsWith('127.');
}

function cameraLabel(camera, index) {
  return camera && camera.id ? String(camera.id) : `camera ${index + 1}`;
}
