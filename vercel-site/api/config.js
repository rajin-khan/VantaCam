module.exports = function handler(req, res) {
  res.setHeader('Content-Type', 'text/javascript; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).send(`window.CAMERA_CONFIG = ${JSON.stringify({
    apiBase: process.env.PI_API_BASE || '',
  })};\n`);
};
