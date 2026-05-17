async function loadHealth() {
  const target = document.getElementById('health');
  try {
    const response = await fetch('/api/health');
    const data = await response.json();
    target.textContent = data.ok ? 'Online' : 'Unhealthy';
  } catch (error) {
    target.textContent = 'Offline';
  }
}

async function loadOverview() {
  const target = document.getElementById('overview');
  try {
    const response = await fetch('/api/overview', { credentials: 'include' });
    if (response.status === 401) {
      setSignedIn(false);
      target.textContent = 'Sign in is required before management data is shown.';
      return;
    }
    const data = await response.json();
    setSignedIn(true);
    target.innerHTML = `
      <dl class="facts">
        <dt>Hostname</dt><dd>${escapeHTML(data.hostname || 'unknown')}</dd>
        <dt>IPs</dt><dd>${escapeHTML((data.ips || []).join(', ') || 'none')}</dd>
        <dt>Uptime</dt><dd>${escapeHTML(data.uptime?.display || 'unknown')}</dd>
        <dt>Load</dt><dd>${escapeHTML(formatLoad(data.load))}</dd>
        <dt>Memory</dt><dd>${escapeHTML(formatPercent(data.memory?.usedPercent))}</dd>
        <dt>Disk</dt><dd>${escapeHTML(formatPercent(data.disk?.usedPercent))}</dd>
      </dl>
    `;
  } catch (error) {
    target.textContent = `Overview unavailable: ${error.message}`;
  }
}

async function login(event) {
  event.preventDefault();
  const username = document.getElementById('username').value;
  const password = document.getElementById('password').value;
  const error = document.getElementById('login-error');
  error.textContent = '';
  try {
    const response = await fetch('/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ username, password }),
    });
    if (!response.ok) {
      error.textContent = response.status === 401 ? 'Invalid password.' : 'Sign in failed.';
      return;
    }
    document.getElementById('password').value = '';
    setSignedIn(true);
    await loadOverview();
  } catch (err) {
    error.textContent = `Sign in failed: ${err.message}`;
  }
}

async function logout() {
  await fetch('/api/logout', { method: 'POST', credentials: 'include' });
  setSignedIn(false);
  document.getElementById('overview').textContent = 'Sign in is required before management data is shown.';
}

function setSignedIn(signedIn) {
  document.getElementById('login-panel').hidden = signedIn;
  document.getElementById('logout-button').hidden = !signedIn;
}

function formatLoad(load) {
  if (!load) return 'unknown';
  return `${load.one?.toFixed?.(2) ?? '0.00'} / ${load.five?.toFixed?.(2) ?? '0.00'} / ${load.fifteen?.toFixed?.(2) ?? '0.00'}`;
}

function formatPercent(value) {
  return typeof value === 'number' ? `${value.toFixed(1)}% used` : 'unknown';
}

function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, ch => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[ch]));
}

loadHealth();
loadOverview();
document.getElementById('login-panel').addEventListener('submit', login);
document.getElementById('logout-button').addEventListener('click', logout);
