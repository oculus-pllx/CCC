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
      target.textContent = 'Sign in is required before management data is shown.';
      return;
    }
    const data = await response.json();
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
