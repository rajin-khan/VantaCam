const loginPanel = document.querySelector('#login-panel');
const consolePanel = document.querySelector('#console');
const loginForm = document.querySelector('#login-form');
const loginStatus = document.querySelector('#login-status');
const cameraGrid = document.querySelector('#camera-grid');
const cardTemplate = document.querySelector('#camera-card-template');
const refreshAllButton = document.querySelector('#refresh-all-button');
const lockButton = document.querySelector('#lock-button');
const fullscreenDialog = document.querySelector('#fullscreen-dialog');
const fullscreenFrame = document.querySelector('#fullscreen-frame');
const fullscreenTitle = document.querySelector('#fullscreen-title');
const fullscreenClose = document.querySelector('#fullscreen-close');
const totalMetric = document.querySelector('#metric-total');
const reachableMetric = document.querySelector('#metric-reachable');
const liveMetric = document.querySelector('#metric-live');
const checkedMetric = document.querySelector('#metric-checked');

const config = window.VANTACAM_FLEET_CONFIG || {};
const cameras = normalizeCameras(config.cameras || []);
const state = new Map();

let refreshTimer = null;

boot();

loginForm.addEventListener('submit', async event => {
  event.preventDefault();
  const password = String(new FormData(loginForm).get('password') || '').trim();
  if (!password) return;

  loginStatus.textContent = 'Unlocking configured cameras...';
  const results = await Promise.all(cameras.map(camera => loginCamera(camera, password)));
  const okCount = results.filter(result => result.ok).length;

  if (okCount === 0) {
    loginStatus.textContent = cameras.length
      ? 'No camera accepted the dashboard password.'
      : 'No cameras are configured.';
    return;
  }

  loginForm.reset();
  showConsole();
  loginStatus.textContent = '';
  await refreshAll();
  startPolling();
});

refreshAllButton.addEventListener('click', refreshAll);

lockButton.addEventListener('click', async () => {
  stopPolling();
  await Promise.all(cameras.map(camera => cameraApi(camera, '/api/logout', { method: 'POST' })));
  state.clear();
  cameraGrid.innerHTML = '';
  fullscreenFrame.removeAttribute('src');
  showLogin();
});

fullscreenClose.addEventListener('click', closeFullscreen);
fullscreenDialog.addEventListener('close', () => fullscreenFrame.removeAttribute('src'));

function boot() {
  totalMetric.textContent = String(cameras.length);
  if (!cameras.length) {
    loginStatus.textContent = 'No cameras are configured yet.';
    showLogin();
    return;
  }

  renderCards();
  showLogin();
}

function normalizeCameras(input) {
  if (!Array.isArray(input)) return [];
  return input
    .map((camera, index) => {
      const apiBase = String(camera.apiBase || '').replace(/\/+$/, '');
      return {
        id: String(camera.id || `camera-${index + 1}`).replace(/[^a-z0-9_-]/gi, '-'),
        name: String(camera.name || `Camera ${index + 1}`),
        kind: String(camera.kind || 'Tailnet camera'),
        apiBase,
        streamUrl: String(camera.streamUrl || ''),
      };
    })
    .filter(camera => camera.apiBase);
}

function renderCards() {
  cameraGrid.innerHTML = '';
  for (const camera of cameras) {
    const card = cardTemplate.content.firstElementChild.cloneNode(true);
    card.dataset.cameraId = camera.id;
    card.querySelector('.camera-kind').textContent = camera.kind;
    card.querySelector('.camera-name').textContent = camera.name;
    card.querySelector('.refresh-button').addEventListener('click', () => refreshCamera(camera));
    card.querySelector('.on-button').addEventListener('click', () => controlCamera(camera, 'on'));
    card.querySelector('.off-button').addEventListener('click', () => controlCamera(camera, 'off'));
    card.querySelector('.copy-button').addEventListener('click', () => copyStreamUrl(camera));
    card.querySelector('.fullscreen-button').addEventListener('click', () => openFullscreen(camera));
    cameraGrid.append(card);
  }
}

async function loginCamera(camera, password) {
  const result = await cameraApi(camera, '/api/login', {
    method: 'POST',
    body: { password },
  });
  state.set(camera.id, {
    ...(state.get(camera.id) || {}),
    authenticated: Boolean(result.ok),
    reachable: !result.error,
    lastError: result.error || '',
  });
  return result;
}

async function refreshAll() {
  await Promise.all(cameras.map(refreshCamera));
  renderSummary();
}

async function refreshCamera(camera) {
  const result = await cameraApi(camera, '/api/status');
  const previous = state.get(camera.id) || {};
  if (result.error) {
    state.set(camera.id, {
      ...previous,
      reachable: false,
      live: false,
      lastError: result.error,
      checkedAt: new Date().toISOString(),
    });
  } else {
    state.set(camera.id, {
      ...previous,
      status: result,
      reachable: true,
      authenticated: true,
      live: result.active === 'active',
      lastError: '',
      checkedAt: result.checkedAt || new Date().toISOString(),
    });
  }
  renderCamera(camera);
  renderSummary();
}

async function controlCamera(camera, action) {
  const card = getCard(camera);
  const passwordInput = card.querySelector('.control-password');
  const statusLine = card.querySelector('.card-status');
  const controlPassword = passwordInput.value;

  if (!controlPassword) {
    statusLine.textContent = 'Enter the stream control password.';
    passwordInput.focus();
    return;
  }

  setCardBusy(camera, true);
  statusLine.textContent = action === 'on' ? 'Starting stream...' : 'Stopping stream...';
  const result = await cameraApi(camera, '/api/control', {
    method: 'POST',
    body: { action, controlPassword },
  });
  setCardBusy(camera, false);

  if (result.error) {
    statusLine.textContent = controlErrorText(result.error);
    await refreshCamera(camera);
    return;
  }

  passwordInput.value = '';
  state.set(camera.id, {
    ...(state.get(camera.id) || {}),
    status: result,
    reachable: true,
    live: result.active === 'active',
    lastError: '',
    checkedAt: result.checkedAt || new Date().toISOString(),
  });
  statusLine.textContent = action === 'on' ? 'Stream is on.' : 'Stream is off.';
  renderCamera(camera);
  renderSummary();
}

function renderCamera(camera) {
  const card = getCard(camera);
  const cameraState = state.get(camera.id) || {};
  const status = cameraState.status || {};
  const isLive = cameraState.live;
  const streamUrl = camera.streamUrl || status.webrtcUrl || '#';

  card.querySelector('.status-chip').className = `status-chip ${statusClass(cameraState)}`;
  card.querySelector('.status-label').textContent = statusLabel(cameraState);
  card.querySelector('.metric-active').textContent = status.active || '--';
  card.querySelector('.metric-enabled').textContent = status.enabled || '--';
  card.querySelector('.metric-path').textContent = status.streamPath || '--';
  card.querySelector('.open-link').href = streamUrl;

  const frame = card.querySelector('.stream-frame');
  const empty = card.querySelector('.viewer-empty');
  if (isLive && streamUrl !== '#') {
    empty.classList.add('is-hidden');
    if (frame.src !== streamUrl) frame.src = streamUrl;
  } else {
    frame.removeAttribute('src');
    empty.classList.remove('is-hidden');
  }

  if (cameraState.lastError) {
    card.querySelector('.card-status').textContent = readableError(cameraState.lastError);
  }
}

function renderSummary() {
  const values = cameras.map(camera => state.get(camera.id) || {});
  totalMetric.textContent = String(cameras.length);
  reachableMetric.textContent = String(values.filter(value => value.reachable).length);
  liveMetric.textContent = String(values.filter(value => value.live).length);
  checkedMetric.textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

async function copyStreamUrl(camera) {
  const cameraState = state.get(camera.id) || {};
  const streamUrl = camera.streamUrl || cameraState.status?.webrtcUrl || '';
  const card = getCard(camera);
  if (!streamUrl) {
    card.querySelector('.card-status').textContent = 'No stream URL is known yet.';
    return;
  }
  await navigator.clipboard.writeText(streamUrl);
  card.querySelector('.card-status').textContent = 'Stream URL copied.';
}

function openFullscreen(camera) {
  const cameraState = state.get(camera.id) || {};
  const streamUrl = camera.streamUrl || cameraState.status?.webrtcUrl || '';
  if (!cameraState.live || !streamUrl) {
    getCard(camera).querySelector('.card-status').textContent = 'Turn the stream on first.';
    return;
  }

  fullscreenTitle.textContent = camera.name;
  fullscreenFrame.src = streamUrl;
  fullscreenDialog.showModal();
  if (fullscreenDialog.requestFullscreen) {
    fullscreenDialog.requestFullscreen().catch(() => {});
  }
}

function closeFullscreen() {
  if (document.fullscreenElement) {
    document.exitFullscreen().catch(() => {});
  }
  fullscreenDialog.close();
}

async function cameraApi(camera, path, options = {}) {
  const init = {
    method: options.method || 'GET',
    credentials: 'include',
    headers: {},
  };

  if (options.body) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(options.body);
  }

  try {
    const response = await fetch(`${camera.apiBase}${path}`, init);
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) return { error: payload.error || 'request_failed' };
    return payload;
  } catch {
    return { error: 'backend_unreachable' };
  }
}

function statusClass(cameraState) {
  if (cameraState.live) return 'live';
  if (cameraState.reachable === false) return 'offline';
  return 'standby';
}

function statusLabel(cameraState) {
  if (cameraState.live) return 'Live';
  if (cameraState.reachable === false) return 'Unreachable';
  return 'Standby';
}

function readableError(error) {
  if (error === 'unauthorized') return 'Locked. Log in again.';
  if (error === 'backend_unreachable') return 'Backend unreachable from this browser.';
  if (error === 'invalid_control_password') return 'Control password did not match.';
  return 'Request failed. Refresh and try again.';
}

function controlErrorText(error) {
  if (error === 'invalid_control_password') return 'Control password did not match.';
  if (error === 'unauthorized') return 'Session expired. Lock and log in again.';
  if (error === 'backend_unreachable') return 'Camera backend is unreachable.';
  return 'Command failed. Refresh and try again.';
}

function setCardBusy(camera, busy) {
  getCard(camera).querySelectorAll('button').forEach(button => {
    button.disabled = busy;
  });
}

function getCard(camera) {
  return cameraGrid.querySelector(`[data-camera-id="${camera.id}"]`);
}

function showLogin() {
  loginPanel.classList.remove('is-hidden');
  consolePanel.classList.add('is-hidden');
}

function showConsole() {
  loginPanel.classList.add('is-hidden');
  consolePanel.classList.remove('is-hidden');
}

function startPolling() {
  stopPolling();
  refreshTimer = setInterval(refreshAll, 15000);
}

function stopPolling() {
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = null;
}
