const titles = {
  overview: 'Overview',
  logs: 'Logs',
  network: 'Network',
  accounts: 'Accounts',
  services: 'Services',
  files: 'Files',
  updates: 'Updates',
  terminal: 'Terminal',
  projects: 'Projects',
  configs: 'Agent Configs',
  oculus: 'oculus-configs',
};

let currentSection = 'overview';
let snapshot = null;

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

async function loadSnapshot() {
  const response = await fetch('/api/workstation', { credentials: 'include' });
  if (response.status === 401) {
    setSignedIn(false);
    document.getElementById('section-body').textContent = 'Sign in is required before management data is shown.';
    return null;
  }
  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || 'snapshot unavailable');
  }
  snapshot = await response.json();
  setSignedIn(true);
  return snapshot;
}

async function refresh() {
  const body = document.getElementById('section-body');
  try {
    body.textContent = 'Loading...';
    await loadSnapshot();
    renderSection(currentSection);
  } catch (error) {
    body.textContent = `Unavailable: ${error.message}`;
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
      error.textContent = response.status === 401 ? 'Invalid username or password.' : 'Sign in failed.';
      return;
    }
    document.getElementById('password').value = '';
    setSignedIn(true);
    await refresh();
  } catch (err) {
    error.textContent = `Sign in failed: ${err.message}`;
  }
}

async function logout() {
  await fetch('/api/logout', { method: 'POST', credentials: 'include' });
  snapshot = null;
  setSignedIn(false);
  document.getElementById('section-body').textContent = 'Sign in is required before management data is shown.';
}

function setSignedIn(signedIn) {
  document.getElementById('login-panel').hidden = signedIn;
  document.getElementById('logout-button').hidden = !signedIn;
  document.getElementById('refresh-button').hidden = !signedIn;
}

function selectSection(section) {
  currentSection = section;
  document.getElementById('section-title').textContent = titles[section] || section;
  document.querySelectorAll('.sidebar button').forEach(button => {
    button.classList.toggle('active', button.dataset.section === section);
  });
  renderSection(section);
}

function renderSection(section) {
  const body = document.getElementById('section-body');
  if (!snapshot) {
    body.textContent = 'Sign in is required before management data is shown.';
    return;
  }
  const renderers = {
    overview: renderOverview,
    logs: renderLogs,
    network: renderNetwork,
    accounts: renderAccounts,
    services: renderServices,
    files: renderFiles,
    updates: renderUpdates,
    terminal: renderTerminal,
    projects: renderProjects,
    configs: renderConfigs,
    oculus: renderOculus,
  };
  body.innerHTML = renderers[section]?.() || '<p>Section unavailable.</p>';
  bindSectionActions(section);
}

function renderOverview() {
  const data = snapshot.overview || {};
  return `
    <dl class="facts">
      <dt>Hostname</dt><dd>${escapeHTML(data.hostname || 'unknown')}</dd>
      <dt>IPs</dt><dd>${escapeHTML((data.ips || []).join(', ') || 'none')}</dd>
      <dt>Uptime</dt><dd>${escapeHTML(data.uptime?.display || 'unknown')}</dd>
      <dt>Load</dt><dd>${escapeHTML(formatLoad(data.load))}</dd>
      <dt>Memory</dt><dd>${escapeHTML(formatPercent(data.memory?.usedPercent))}</dd>
      <dt>Disk</dt><dd>${escapeHTML(formatPercent(data.disk?.usedPercent))}</dd>
    </dl>
  `;
}

function renderServices() {
  return `
    <div class="action-row">
      <button class="small-button" data-action="restart-code-server">Restart VS Code Web</button>
      <button class="small-button" data-action="restart-agent-workstation">Restart Agent Workstation</button>
    </div>
    ${table(['Service', 'Active', 'Enabled', 'Description'], (snapshot.services || []).map(service => [
      service.name,
      service.active || 'unknown',
      service.sub || 'unknown',
      service.description || '',
    ]))}
    <pre id="action-output" class="output" hidden></pre>
  `;
}

function renderLogs() {
  return (snapshot.logs || []).map(log => `
    <section class="stack">
      <h3>${escapeHTML(log.name)}</h3>
      <pre class="output">${escapeHTML(log.lines || 'No recent log lines.')}</pre>
    </section>
  `).join('') || '<p>No logs available.</p>';
}

function renderNetwork() {
  return `
    <h3>Addresses</h3>
    <pre class="output">${escapeHTML(snapshot.network?.addresses || 'No address data.')}</pre>
    <h3>Routes</h3>
    <pre class="output">${escapeHTML(snapshot.network?.routes || 'No route data.')}</pre>
  `;
}

function renderAccounts() {
  return table(['User', 'UID', 'Groups', 'Home', 'Shell'], (snapshot.accounts || []).map(account => [
    account.username,
    account.uid,
    account.groups,
    account.home,
    account.shell,
  ]));
}

function renderFiles() {
  return table(['Name', 'Type', 'Size', 'Modified', 'Path'], (snapshot.files || []).map(file => [
    file.name,
    file.type,
    formatBytes(file.size),
    file.mtime,
    file.path,
  ]));
}

function renderUpdates() {
  return `
    <div class="action-row">
      <button class="small-button" data-action="update-status">Refresh Agent Workstation Status</button>
      <button class="small-button" data-action="os-update">Run OS Update</button>
    </div>
    <h3>Agent Workstation</h3>
    <pre class="output">${escapeHTML(snapshot.updates?.agentWorkstation || 'No Agent Workstation update status.')}</pre>
    <h3>OS Packages</h3>
    <pre class="output">${escapeHTML(snapshot.updates?.os || 'No package update data.')}</pre>
    <pre id="action-output" class="output" hidden></pre>
  `;
}

function renderTerminal() {
  const cwd = snapshot.projects?.[0]?.path || '';
  return `
    <form id="terminal-form" class="terminal-form">
      <label for="terminal-cwd">Working directory</label>
      <input id="terminal-cwd" type="text" value="${escapeAttribute(cwd)}" placeholder="/home/oculus/projects">
      <label for="terminal-command">Command</label>
      <div class="login-row">
        <input id="terminal-command" type="text" autocomplete="off" placeholder="pwd">
        <button type="submit">Run</button>
      </div>
    </form>
    <pre id="terminal-output" class="output">Command output will appear here.</pre>
  `;
}

function renderProjects() {
  return table(['Project', 'Branch', 'Status', 'Path'], (snapshot.projects || []).map(project => [
    project.name,
    project.gitBranch || 'not a git repo',
    project.gitStatus || '',
    project.path,
  ]));
}

function renderConfigs() {
  return table(['Config', 'Exists', 'Size', 'Path'], (snapshot.agentConfigs || []).map(config => [
    config.name,
    config.exists ? 'yes' : 'no',
    formatBytes(config.size),
    config.path,
  ]));
}

function renderOculus() {
  const repo = snapshot.oculusConfigs || {};
  return `
    <div class="action-row">
      <button class="small-button" data-action="sync-oculus-configs">Sync oculus-configs</button>
    </div>
    <dl class="facts">
      <dt>Path</dt><dd>${escapeHTML(repo.path || '/opt/oculus-configs')}</dd>
      <dt>Exists</dt><dd>${repo.exists ? 'yes' : 'no'}</dd>
      <dt>Branch</dt><dd>${escapeHTML(repo.branch || 'unknown')}</dd>
      <dt>Head</dt><dd>${escapeHTML(repo.head || 'unknown')}</dd>
      <dt>Last Commit</dt><dd>${escapeHTML(repo.lastCommit || 'unknown')}</dd>
    </dl>
    <h3>Status</h3>
    <pre class="output">${escapeHTML(repo.status || 'No git status available.')}</pre>
    <h3>Pending Commit Preview</h3>
    <pre class="output">${escapeHTML(repo.pending || 'No pending diff.')}</pre>
    <pre id="action-output" class="output" hidden></pre>
  `;
}

function bindSectionActions(section) {
  document.querySelectorAll('[data-action]').forEach(button => {
    button.addEventListener('click', () => runAction(button.dataset.action));
  });
  if (section === 'terminal') {
    document.getElementById('terminal-form').addEventListener('submit', runTerminal);
  }
}

async function runAction(action) {
  const output = document.getElementById('action-output');
  output.hidden = false;
  output.textContent = 'Running...';
  try {
    const result = await postJSON('/api/action', { action });
    output.textContent = result.output || `Exit code ${result.exitCode}`;
    await loadSnapshot();
  } catch (error) {
    output.textContent = error.message;
  }
}

async function runTerminal(event) {
  event.preventDefault();
  const command = document.getElementById('terminal-command').value;
  const cwd = document.getElementById('terminal-cwd').value;
  const output = document.getElementById('terminal-output');
  output.textContent = 'Running...';
  try {
    const result = await postJSON('/api/terminal', { command, cwd });
    output.textContent = `$ ${result.command}\n${result.output || ''}\nexit ${result.exitCode}`;
  } catch (error) {
    output.textContent = error.message;
  }
}

async function postJSON(url, body) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include',
    body: JSON.stringify(body),
  });
  const text = await response.text();
  let data = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch (error) {
    data = { error: text };
  }
  if (!response.ok) {
    throw new Error(data.error || `Request failed with ${response.status}`);
  }
  return data;
}

function table(headers, rows) {
  if (!rows.length) return '<p>No data available.</p>';
  return `
    <div class="table-wrap">
      <table>
        <thead><tr>${headers.map(header => `<th>${escapeHTML(header)}</th>`).join('')}</tr></thead>
        <tbody>${rows.map(row => `<tr>${row.map(cell => `<td>${escapeHTML(cell ?? '')}</td>`).join('')}</tr>`).join('')}</tbody>
      </table>
    </div>
  `;
}

function formatLoad(load) {
  if (!load) return 'unknown';
  return `${load.one?.toFixed?.(2) ?? '0.00'} / ${load.five?.toFixed?.(2) ?? '0.00'} / ${load.fifteen?.toFixed?.(2) ?? '0.00'}`;
}

function formatPercent(value) {
  return typeof value === 'number' ? `${value.toFixed(1)}% used` : 'unknown';
}

function formatBytes(value) {
  if (!Number.isFinite(value) || value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${size.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
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

function escapeAttribute(value) {
  return escapeHTML(value).replace(/`/g, '&#96;');
}

loadHealth();
refresh();
document.getElementById('login-panel').addEventListener('submit', login);
document.getElementById('logout-button').addEventListener('click', logout);
document.getElementById('refresh-button').addEventListener('click', refresh);
document.querySelectorAll('.sidebar button').forEach(button => {
  button.addEventListener('click', () => selectSection(button.dataset.section));
});
