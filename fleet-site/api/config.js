module.exports = function handler(req, res) {
  const cameras = parseCameras(process.env.FLEET_CAMERAS_JSON || '[]');
  res.setHeader('Content-Type', 'text/javascript; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).send(`window.VANTACAM_FLEET_CONFIG = ${JSON.stringify({ cameras })};\n`);
};

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
