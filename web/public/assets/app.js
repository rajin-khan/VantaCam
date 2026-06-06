const loginPanel = document.querySelector('#login-panel');
const consolePanel = document.querySelector('#console');
const loginForm = document.querySelector('#login-form');
const loginStatus = document.querySelector('#login-status');
const controlStatus = document.querySelector('#control-status');
const controlPassword = document.querySelector('#control-password');
const statusPill = document.querySelector('#status-pill');
const statusLabel = document.querySelector('#status-label');
const streamFrame = document.querySelector('#stream-frame');
const viewerEmpty = document.querySelector('#viewer-empty');
const webrtcLink = document.querySelector('#webrtc-link');
const activeMetric = document.querySelector('#metric-active');
const enabledMetric = document.querySelector('#metric-enabled');
const checkedMetric = document.querySelector('#metric-checked');
const streamPath = document.querySelector('#stream-path');
const cameraConfig = window.CAMERA_CONFIG || {};
const apiBase = String(cameraConfig.apiBase || '').replace(/\/+$/, '');

let latestStatus = null;
let pendingAction = false;

boot();

async function boot() {
  const session = await api('/api/session');
  if (session.error) {
    showLogin();
    loginStatus.textContent = 'Camera backend is unreachable.';
    return;
  }

  if (session.authenticated) {
    showConsole();
    await refreshStatus();
    setInterval(refreshStatus, 15000);
  } else {
    showLogin();
  }
}

loginForm.addEventListener('submit', async event => {
  event.preventDefault();
  loginStatus.textContent = 'Checking password...';
  const password = String(new FormData(loginForm).get('password') || '').trim();
  const result = await api('/api/login', { method: 'POST', body: { password } });
  if (result.ok) {
    loginForm.reset();
    showConsole();
    await refreshStatus();
    loginStatus.textContent = '';
    return;
  }
  loginStatus.textContent = result.error === 'backend_unreachable'
    ? 'Camera backend is unreachable.'
    : 'Password did not match.';
});

document.querySelector('#logout-button').addEventListener('click', async () => {
  await api('/api/logout', { method: 'POST' });
  streamFrame.removeAttribute('src');
  showLogin();
});

document.querySelector('#refresh-button').addEventListener('click', refreshStatus);
document.querySelector('#on-button').addEventListener('click', () => control('on'));
document.querySelector('#off-button').addEventListener('click', () => control('off'));
document.querySelector('#copy-url-button').addEventListener('click', async () => {
  if (!latestStatus) return;
  await navigator.clipboard.writeText(latestStatus.webrtcUrl);
  controlStatus.textContent = 'WebRTC URL copied.';
});

async function control(action) {
  if (pendingAction) return;
  pendingAction = true;
  controlStatus.textContent = action === 'on' ? 'Starting stream...' : 'Stopping stream...';
  const result = await api('/api/control', {
    method: 'POST',
    body: {
      action,
      controlPassword: controlPassword.value,
    },
  });
  pendingAction = false;

  if (result.error) {
    if (result.error === 'invalid_control_password') {
      controlStatus.textContent = 'Control password did not match.';
    } else if (result.error === 'unauthorized') {
      controlStatus.textContent = 'Session expired. Lock and log in again.';
    } else if (result.error === 'backend_unreachable') {
      controlStatus.textContent = 'Camera backend is unreachable.';
    } else {
      controlStatus.textContent = 'Command failed. Refresh and try again.';
    }
    return;
  }

  controlPassword.value = '';
  latestStatus = result;
  renderStatus(result);
  controlStatus.textContent = action === 'on' ? 'Stream is on.' : 'Stream is off.';
}

async function refreshStatus() {
  const result = await api('/api/status');
  if (result.error) {
    renderOffline(result.error === 'unauthorized' ? 'Locked' : 'Unreachable');
    return;
  }
  latestStatus = result;
  renderStatus(result);
}

function renderStatus(status) {
  const isLive = status.active === 'active';
  statusPill.className = isLive ? 'status-chip live' : 'status-chip offline';
  statusLabel.textContent = isLive ? 'Live' : 'Offline';
  activeMetric.textContent = status.active;
  enabledMetric.textContent = status.enabled;
  checkedMetric.textContent = new Date(status.checkedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  streamPath.textContent = status.streamPath;
  webrtcLink.href = status.webrtcUrl;

  if (isLive) {
    viewerEmpty.classList.add('is-hidden');
    if (streamFrame.src !== status.webrtcUrl) {
      streamFrame.src = status.webrtcUrl;
    }
  } else {
    streamFrame.removeAttribute('src');
    viewerEmpty.classList.remove('is-hidden');
  }
}

function renderOffline(label) {
  statusPill.className = 'status-chip offline';
  statusLabel.textContent = label;
  activeMetric.textContent = '--';
  enabledMetric.textContent = '--';
  checkedMetric.textContent = '--';
  viewerEmpty.classList.remove('is-hidden');
}

function showLogin() {
  loginPanel.classList.remove('is-hidden');
  consolePanel.classList.add('is-hidden');
}

function showConsole() {
  loginPanel.classList.add('is-hidden');
  consolePanel.classList.remove('is-hidden');
}

async function api(url, options = {}) {
  const init = {
    method: options.method || 'GET',
    headers: {},
    credentials: 'include',
  };
  if (options.body) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(options.body);
  }

  try {
    const response = await fetch(`${apiBase}${url}`, init);
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) return { error: payload.error || 'request_failed' };
    return payload;
  } catch {
    return { error: 'backend_unreachable' };
  }
}
