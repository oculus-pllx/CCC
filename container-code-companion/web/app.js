const titles = {
  overview: 'Overview',
  logs: 'Logs',
  network: 'Network',
  accounts: 'Accounts',
  services: 'Services',
  files: 'Files',
  notes: 'Notes',
  updates: 'Updates',
  terminal: 'Terminal',
  apps: 'App Catalog',
  drives: 'Map Drives',
  projects: 'Projects',
  configs: 'Provider Configs',
  oculus: 'oculus-configs',
  github: 'GitHub',
  settings: 'Preferences',
};

const THEMES = {
  green:  '#4ade80',
  purple: '#a78bfa',
  cyan:   '#22d3ee',
  amber:  '#f59e0b',
  red:    '#f87171',
  pink:   '#f472b6',
  white:  '#e2e8f0',
};
const DEFAULT_THEME = 'green';
const THEME_STORAGE_KEY = 'ccc-theme';
const CCC_CUSTOM_TITLE_STORAGE_KEY = 'ccc-custom-title';
const DISPLAY_EFFECTS_STORAGE_KEY = 'ccc-display-effects';
const TERMINAL_HEIGHT_STORAGE_KEY = 'ccc-terminal-height';
const DEFAULT_DISPLAY_EFFECTS = {
  flicker: true,
  syncDrift: false,
};

let currentSection = 'overview';
let snapshot = null;
let filePath = '';
let currentFile = '';
let selectedFilePath = '';
let notesCache = [];
let activeNoteId = '';
let notesDirty = false;
let terminalSocket = null;
let terminal = null;
let rawTerminalBuffer = '';
let terminalTabs = [];
let activeTerminalTabId = null;
let nextTerminalTabId = 1;
let updatePollTimer = null;
let snapshotPollTimer = null;
let activeUpdateTab = 'app';
let networkPollTimer = null;
let lastNetworkSample = null;
let networkHistory = [];
let terminalInitialized = false;

async function loadHealth() {
  const target = document.getElementById('health');
  try {
    const response = await fetch('/api/health');
    const data = await response.json();
    target.textContent = data.ok ? 'Online' : 'Unhealthy';
    // #health.online activates the pulse-dot ::before animation
    target.classList.toggle('online', !!data.ok);
  } catch {
    target.textContent = 'Offline';
    target.classList.remove('online');
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

async function fetchWorkstationData() {
  try {
    const response = await fetch('/api/workstation', { credentials: 'include' });
    if (!response.ok) return null;
    return await response.json();
  } catch {
    return null;
  }
}

async function refresh() {
  const body = document.getElementById('section-body');
  try {
    body.textContent = 'Loading...';
    const data = await loadSnapshot();
    if (data) startSnapshotPolling();
    renderSection(currentSection);
  } catch (error) {
    body.textContent = `Unavailable: ${error.message}`;
  }
}

async function pollSnapshot() {
  const data = await fetchWorkstationData();
  if (!data) {
    stopSnapshotPolling();
    return;
  }
  snapshot = data;
  setSignedIn(true);
  if (currentSection === 'updates' || currentSection === 'overview') {
    if (currentSection === 'overview') {
      updateOverviewLive();
    } else {
      renderSection(currentSection);
    }
  }
}

function startSnapshotPolling() {
  if (snapshotPollTimer) return;
  snapshotPollTimer = setInterval(pollSnapshot, 30000);
}

function stopSnapshotPolling() {
  if (!snapshotPollTimer) return;
  clearInterval(snapshotPollTimer);
  snapshotPollTimer = null;
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
  stopSnapshotPolling();
  snapshot = null;
  setSignedIn(false);
  networkHistory = [];
  lastNetworkSample = null;
  stopTerminalSessions();
  terminalTabs = [];
  activeTerminalTabId = null;
  nextTerminalTabId = 1;
  terminalInitialized = false;
  const termContainer = document.getElementById('terminal-container');
  termContainer.hidden = true;
  termContainer.innerHTML = '';
  const body = document.getElementById('section-body');
  body.hidden = false;
  body.textContent = 'Sign in is required before management data is shown.';
}

function setSignedIn(signedIn) {
  document.body.classList.toggle('signed-out', !signedIn);
  document.getElementById('app-shell').hidden = !signedIn;
  document.getElementById('login-shell').hidden = signedIn;
  document.getElementById('logout-button').hidden = !signedIn;
  document.getElementById('refresh-button').hidden = !signedIn;
  if (signedIn) startNetworkBackground();
  else stopNetworkGraph();
}

function startNetworkBackground() {
  if (networkPollTimer) return;
  pollNetworkActivity();
  networkPollTimer = setInterval(pollNetworkActivity, 2000);
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
  const termContainer = document.getElementById('terminal-container');

  if (section === 'terminal') {
    if (!snapshot) {
      body.hidden = false;
      termContainer.hidden = true;
      body.textContent = 'Sign in is required before management data is shown.';
      return;
    }
    body.hidden = true;
    termContainer.hidden = false;
    if (!terminalInitialized) {
      termContainer.innerHTML = renderTerminal();
      terminalInitialized = true;
      bindTerminal();
    }
    return;
  }

  body.hidden = false;
  termContainer.hidden = true;

  if (!snapshot && section !== 'settings' && section !== 'github' && section !== 'apps' && section !== 'drives') {
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
    notes: renderNotes,
    updates: renderUpdates,
    apps: renderAppCatalog,
    drives: renderMapDrives,
    projects: renderProjects,
    configs: renderConfigs,
    oculus: renderOculus,
    github: renderGitHub,
    settings: renderSettings,
  };
  body.innerHTML = renderers[section]?.() || '<p>Section unavailable.</p>';
  body.classList.remove('section-enter');
  void body.offsetWidth;
  body.classList.add('section-enter');
  bindSectionActions(section);
}

function renderOverview() {
  const data = snapshot.overview || {};
  const services = snapshot.services || [];
  const activeServices = services.filter(service => service.active === 'active').length;
  const totalServices = services.length;
  const cpuPercent = loadPercent(data.load?.one, data.cpu?.cores);
  const updateText = stripANSI(snapshot.updates?.containerCodeCompanion || '');
  const updateLog = stripANSI(snapshot.updates?.selfUpdateLog || '');
  const updateBadge = updateStatusBadge(updateText, updateLog);
  const configs = snapshot.agentConfigs || [];
  const presentConfigs = configs.filter(config => config.exists).length;
  const logs = snapshot.logs || [];
  const primaryLog = stripANSI(logs[0]?.lines || '').split('\n').slice(-8).join('\n');
  return `
    <div class="dashboard">
      <section class="status-strip">
        ${statusTile('Host', data.hostname || 'unknown')}
        ${statusTile('IP', (data.ips || [])[0] || 'none')}
        ${statusTile('Uptime', data.uptime?.display || 'unknown')}
        ${statusTile('Services', `${activeServices}/${totalServices} active`)}
        ${statusTile('Projects', `${(snapshot.projects || []).length}`)}
      </section>

      <section class="gauge-grid">
        ${gauge('CPU Load', cpuPercent, `${formatLoad(data.load)} · ${data.cpu?.cores || 1} cores`, 'cpu')}
        ${gauge('Memory', data.memory?.usedPercent, `${formatBytes(usedBytes(data.memory))} / ${formatBytes(data.memory?.totalBytes || 0)}`, 'memory')}
        ${gauge('Disk', data.disk?.usedPercent, `${formatBytes(data.disk?.usedBytes || 0)} / ${formatBytes(data.disk?.totalBytes || 0)} on ${data.disk?.mount || '/'}`, 'disk')}
      </section>

      <section class="dashboard-grid">
        <div class="dash-panel">
          <h3>Update Status</h3>
          <button class="badge badge-link ${updateBadge === 'Current' ? 'ok' : updateBadge === 'Updates available' ? 'warn' : ''}" data-nav-updates>${escapeHTML(updateBadge)}</button>
          <pre class="mini-output">${escapeHTML(firstUsefulLines(updatePanelText(updateText, updateLog), 8))}</pre>
        </div>
        <div class="dash-panel">
          <h3>Provider Configs</h3>
          <span class="badge ${presentConfigs === configs.length ? 'ok' : 'warn'}">${presentConfigs}/${configs.length} present</span>
          ${configs.map(config => `<div class="mini-row"><span>${escapeHTML(config.name)}</span><strong>${config.exists ? 'ready' : 'missing'}</strong></div>`).join('')}
        </div>
        <div class="dash-panel">
          <h3>Services</h3>
          ${services.map(service => `<div class="mini-row"><span>${escapeHTML(service.name)}</span><strong class="${service.active === 'active' ? 'ok-text' : 'warn-text'}">${escapeHTML(service.active || 'unknown')}</strong></div>`).join('')}
        </div>
        <div class="dash-panel">
          <h3>Recent Activity</h3>
          <pre class="mini-output">${escapeHTML(primaryLog || 'No recent Container Code Companion logs.')}</pre>
        </div>
      </section>
    </div>
  `;
}

function renderServices() {
  return `
    <div class="service-list">
      ${(snapshot.services || []).map(service => `
        <section class="service-row">
          <div>
            <strong>${escapeHTML(service.name)}</strong>
            <p>${escapeHTML(service.description || '')}</p>
            <span>${escapeHTML(service.active || 'unknown')} / ${escapeHTML(service.sub || 'unknown')}</span>
          </div>
          <div class="action-row">
            ${['start', 'stop', 'restart', 'enable', 'disable'].map(operation => `
              <button class="small-button" data-service="${escapeAttribute(service.name)}" data-operation="${operation}">${operation}</button>
            `).join('')}
          </div>
        </section>
      `).join('')}
    </div>
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
    <h3>Activity</h3>
    <div class="network-graph-wrap">
      <canvas id="network-graph" width="900" height="220"></canvas>
      <div class="network-legend">
        <span class="network-legend-rx">&#9644; Download (RX)</span>
        <span class="network-legend-tx">&#9644; Upload (TX)</span>
        <span id="network-rate">Collecting samples...</span>
      </div>
    </div>
    <h3>Addresses</h3>
    <pre class="output">${escapeHTML(snapshot.network?.addresses || 'No address data.')}</pre>
    <h3>Routes</h3>
    <pre class="output">${escapeHTML(snapshot.network?.routes || 'No route data.')}</pre>
  `;
}

function renderAccounts() {
  const accounts = snapshot.accounts || [];
  return `
    <div class="account-create">
      <input id="account-username" type="text" placeholder="username">
      <input id="account-password" type="password" placeholder="initial password">
      <input id="account-shell" type="text" value="/bin/bash" placeholder="/bin/bash">
      <button id="create-account-button" class="small-button">Create Account</button>
    </div>
    <div class="account-list">
      ${accounts.map(account => `
        <section class="account-row">
          <div>
            <strong>${escapeHTML(account.username)}</strong>
            <p>${escapeHTML(account.home)} · UID ${escapeHTML(account.uid)}</p>
            <span>${escapeHTML(account.groups || 'no groups')} · ${escapeHTML(account.shell)}</span>
          </div>
          <div class="action-row">
            <button class="small-button" data-account-password="${escapeAttribute(account.username)}">Password</button>
            <button class="small-button" data-account-shell="${escapeAttribute(account.username)}" data-current-shell="${escapeAttribute(account.shell)}">Shell</button>
            <button class="small-button" data-account-groups="${escapeAttribute(account.username)}" data-current-groups="${escapeAttribute(account.groups)}">Groups</button>
            <button class="small-button danger-button" data-account-delete="${escapeAttribute(account.username)}">Delete</button>
          </div>
        </section>
      `).join('') || '<p>No user accounts found.</p>'}
    </div>
    <pre id="account-output" class="output" hidden></pre>
  `;
}

function renderFiles() {
  if (!filePath) {
    filePath = snapshot.projects?.[0]?.path || '/';
  }
  return `
    <div class="file-manager">
      <div class="file-toolbar">
        <button id="file-home-button" class="small-button">Home</button>
        <button id="file-projects-button" class="small-button">Projects</button>
        <button id="parent-button" class="small-button">Up</button>
        <button id="file-refresh-button" class="small-button">Refresh</button>
        <input id="file-path" type="text" value="${escapeAttribute(filePath)}">
        <button id="browse-button" class="small-button">Open</button>
      </div>
      <div id="file-breadcrumbs" class="file-breadcrumbs">${renderFileBreadcrumbs(filePath)}</div>
      <div class="file-toolbar file-action-toolbar">
        <button id="file-new-file-button" class="small-button">New File</button>
        <button id="file-new-folder-button" class="small-button">New Folder</button>
        <label class="small-button file-upload-label" for="file-upload-input">Upload</label>
        <input id="file-upload-input" type="file" hidden>
        <button id="file-download-button" class="small-button">Download</button>
        <button id="file-copy-button" class="small-button">Copy</button>
        <button id="file-rename-button" class="small-button">Rename</button>
        <button id="file-chmod-button" class="small-button">chmod</button>
        <button id="file-delete-button" class="small-button danger-button">Delete</button>
      </div>
    </div>
    <div class="file-browser">
      <div>
        <div class="file-section-header">
          <h3>Directory</h3>
          <span id="file-count" class="muted">Loading...</span>
        </div>
        <div class="file-table-header" aria-hidden="true">
          <span>Type</span>
          <span>Name</span>
          <span>Size</span>
          <span>Modified</span>
        </div>
        <div id="file-list" class="file-list">Loading...</div>
      </div>
      <div>
        <div class="file-section-header">
          <h3>Editor</h3>
          <span id="file-selected-detail" class="file-selected-detail">No file selected</span>
        </div>
        <div class="file-toolbar">
          <input id="current-file" type="text" value="${escapeAttribute(currentFile)}" placeholder="Select a file">
          <button id="save-file-button" class="small-button">Save</button>
        </div>
        <textarea id="file-editor" spellcheck="false"></textarea>
        <pre id="file-output" class="output" hidden></pre>
      </div>
    </div>
  `;
}

function renderFileBreadcrumbs(path) {
  const parts = String(path || '/').split('/').filter(Boolean);
  const crumbs = ['<button type="button" data-file-breadcrumb="/">/</button>'];
  let current = '';
  parts.forEach(part => {
    current += `/${part}`;
    crumbs.push(`<button type="button" data-file-breadcrumb="${escapeAttribute(current)}">${escapeHTML(part)}</button>`);
  });
  return crumbs.join('<span>/</span>');
}

function renderNotes() {
  return `
    <div class="notes-layout">
      <aside class="notes-sidebar">
        <div class="notes-toolbar">
          <button id="notes-new-button" class="small-button">New Note</button>
          <button id="notes-refresh-button" class="small-button">Refresh</button>
        </div>
        <div id="notes-list" class="notes-list">Loading notes...</div>
      </aside>
      <section class="notes-editor-panel">
        <div class="notes-title-row">
          <input id="notes-title-input" type="text" maxlength="120" placeholder="Note title" autocomplete="off">
          <button id="notes-save-button" class="small-button">Save</button>
          <button id="notes-delete-button" class="small-button danger-button">Delete</button>
        </div>
        <textarea id="notes-editor" class="notes-editor" spellcheck="true" placeholder="Write notes here..."></textarea>
        <div class="notes-status-row">
          <span id="notes-status" class="muted">Select or create a note.</span>
          <span id="notes-updated" class="muted"></span>
        </div>
      </section>
    </div>
  `;
}

function renderUpdates() {
  return renderUpdateConsole();
}

function renderUpdateConsole() {
  const updateText = stripANSI(snapshot.updates?.containerCodeCompanion || '');
  const osUpdateText = formatOSPackageStatus(snapshot.updates?.os || '');
  const updateLog = stripANSI(snapshot.updates?.selfUpdateLog || '');
  const isAppTab = activeUpdateTab === 'app';
  return `
    <div class="update-console">
      <div class="update-tabs" role="tablist" aria-label="Update sections">
        <button class="update-tab ${isAppTab ? 'active' : ''}" type="button" role="tab" aria-selected="${isAppTab}" data-update-tab="app">App</button>
        <button class="update-tab ${!isAppTab ? 'active' : ''}" type="button" role="tab" aria-selected="${!isAppTab}" data-update-tab="os">OS</button>
      </div>
      ${isAppTab ? renderAppUpdateTab(updateText, updateLog) : renderOSUpdateTab(osUpdateText)}
    </div>
  `;
}

function renderAppUpdateTab(updateText, updateLog) {
  const updateBadge = updateStatusBadge(updateText, updateLog);
  const logPreview = firstUsefulLines(updateLog, 10);
  return `
    <div class="update-summary">
      <div>
        <h3>Container Code Companion</h3>
        <p class="section-description">Pull the latest Container Code Companion source from GitHub, rebuild the native UI, sync web assets, and restart the service.</p>
      </div>
      <span class="badge ${updateBadgeClass(updateBadge)}">${escapeHTML(updateBadge)}</span>
    </div>
    <div class="action-row">
      <button class="small-button" id="self-update-btn">Update App</button>
    </div>
    <pre id="update-status-output" class="output">${escapeHTML(updateText || 'No Container Code Companion update status.')}</pre>
    ${logPreview ? `
      <div class="update-log-panel">
        <h3>Recent App Update Log</h3>
        <pre class="output">${escapeHTML(logPreview)}</pre>
      </div>
    ` : ''}
    <pre id="self-update-output" class="output" hidden></pre>
  `;
}

function renderOSUpdateTab(osUpdateText) {
  const osBadge = osUpdateText === 'No OS package updates available.' ? 'Current' : 'Updates available';
  return `
    <div class="update-summary">
      <div>
        <h3>OS Packages</h3>
        <p class="section-description">Run apt package updates for the LXC operating system without changing Container Code Companion application code.</p>
      </div>
      <span class="badge ${updateBadgeClass(osBadge)}">${escapeHTML(osBadge)}</span>
    </div>
    <div class="action-row">
      <button class="small-button" id="os-update-btn">Update OS</button>
    </div>
    <pre class="output">${escapeHTML(osUpdateText)}</pre>
    <pre id="action-output" class="output" hidden></pre>
  `;
}

function renderTerminal() {
  ensureTerminalTab();
  return `
    <div class="terminal-tabs">
      <div id="terminal-tab-list" class="terminal-tab-list">
        ${terminalTabs.map(tab => `
          <button class="terminal-tab ${tab.id === activeTerminalTabId ? 'active' : ''}" data-terminal-tab="${tab.id}">
            ${escapeHTML(tab.name)}
          </button>
        `).join('')}
      </div>
      <button id="terminal-new-tab" class="small-button">New Tab</button>
    </div>
    <div class="action-row">
      <button id="terminal-connect" class="small-button">Connect</button>
      <button id="terminal-disconnect" class="small-button">Disconnect</button>
      <button id="terminal-tmux" class="small-button">tmux</button>
      <button class="small-button" data-tmux-command="tmux new-session -A -s work">Attach</button>
      <button class="small-button" data-tmux-command="tmux split-window -h">Split</button>
      <button class="small-button" data-tmux-command="tmux detach-client">Detach</button>
      <button class="small-button" data-tmux-command="tmux list-sessions">List</button>
      <button class="small-button" data-tmux-command="tmux copy-mode">Scroll</button>
      <span id="terminal-status">${escapeHTML(activeTerminalTab()?.status || 'Disconnected')}</span>
    </div>
    <div class="terminal-size-control">
      <label for="terminal-height-slider">Terminal height</label>
      <input id="terminal-height-slider" type="range" min="360" max="900" step="20" value="${escapeAttribute(loadTerminalHeight())}">
      <span id="terminal-height-value">${escapeHTML(loadTerminalHeight())}px</span>
    </div>
    <div id="terminal-panes">
      ${terminalTabs.map(tab => `<div id="terminal-pane-${tab.id}" class="terminal-pane" ${tab.id === activeTerminalTabId ? '' : 'hidden'}></div>`).join('')}
    </div>
    <div id="terminal-fallback" hidden>
      <pre id="terminal-raw-output" class="output">Raw terminal output will appear here.</pre>
      <div class="login-row">
        <input id="terminal-raw-input" type="text" autocomplete="off" placeholder="type command or input">
        <button id="terminal-raw-send" type="button">Send</button>
      </div>
    </div>
  `;
}

function renderProjects() {
  return `
    <div class="project-create">
      <input id="project-name" type="text" placeholder="new-project">
      <select id="project-template">
        <option value="blank">Blank project</option>
      </select>
      <button id="create-project-button" class="small-button">Create</button>
    </div>
    <div class="project-create project-add-existing">
      <input id="existing-project-name" type="text" placeholder="project-name">
      <input id="existing-project-path" type="text" placeholder="/path/to/existing/directory">
      <button id="add-existing-project-button" class="small-button">Add Existing Directory</button>
    </div>
    <div class="project-list">
      ${(snapshot.projects || []).map(project => `
        <section class="project-row">
          <div>
            <strong>${escapeHTML(project.name)}</strong>
            <p>${escapeHTML(project.path)}</p>
            <span>${escapeHTML(project.gitBranch || 'not a git repo')}</span>
          </div>
          <div class="action-row">
            <button class="small-button" data-project-browse="${escapeAttribute(project.path)}">Files</button>
            <button class="small-button" data-project-open="${escapeAttribute(project.path)}">VS Code</button>
            <button class="small-button" data-project-rename="${escapeAttribute(project.name)}">Rename</button>
            <button class="small-button danger-button" data-project-delete="${escapeAttribute(project.name)}">Delete</button>
          </div>
        </section>
      `).join('') || '<p>No projects yet.</p>'}
    </div>
    <pre id="project-output" class="output" hidden></pre>
  `;
}

function renderConfigs() {
  const configs = snapshot.agentConfigs || [];
  if (!configs.length) return '<p>No agent config files found.</p>';
  return `
    <div class="config-list">
      ${configs.map(config => `
        <section class="config-row">
          <div>
            <strong>${escapeHTML(config.name)}</strong>
            <p>${escapeHTML(config.path)}</p>
            <span>${config.exists ? escapeHTML(formatBytes(config.size)) : 'missing'}</span>
          </div>
          <button class="small-button" data-config-edit="${escapeAttribute(config.path)}">Edit</button>
        </section>
      `).join('')}
    </div>
    <div id="config-editor-panel" class="config-editor-panel" hidden>
      <div class="config-editor-header">
        <strong id="config-editor-title"></strong>
        <div class="action-row">
          <button id="config-editor-save" class="small-button">Save</button>
          <button id="config-editor-cancel" class="small-button">Cancel</button>
        </div>
      </div>
      <textarea id="config-editor-textarea" class="config-editor-textarea" spellcheck="false"></textarea>
      <pre id="config-editor-output" class="output" hidden></pre>
    </div>
  `;
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

function renderGitHub() {
  return `
    <p class="section-description">Create an SSH key for this workstation and authorize it on GitHub to enable git operations over SSH.</p>
    <div id="github-key-panel">
      <p class="muted">Loading SSH key status...</p>
    </div>
    <div class="action-row">
      <button class="small-button" id="github-generate-btn">Generate New SSH Key</button>
      <button class="small-button" id="github-test-btn">Test GitHub Connection</button>
    </div>
    <pre id="github-output" class="output" hidden></pre>
  `;
}

function renderSettings() {
  const current = localStorage.getItem(THEME_STORAGE_KEY) || DEFAULT_THEME;
  const effects = loadDisplayEffects();
  const customTitle = customTitleValue();
  return `
    <div class="settings-section settings-section-wide">
      <h3>Header Message</h3>
      <p class="section-description">This text appears near the top of every main view.</p>
      <div class="settings-title-form">
        <input id="custom-title-input" type="text" maxlength="96" autocomplete="off" spellcheck="false" value="${escapeAttribute(customTitle)}" placeholder="Container Code Companion">
        <button id="custom-title-reset" class="small-button">Reset</button>
      </div>
    </div>
    <div class="settings-section">
      <h3>Theme</h3>
      <div class="settings-swatch-grid">
        ${Object.entries(THEMES).map(([name, hex]) => `
          <button class="settings-swatch-row${name === current ? ' active' : ''}" data-theme="${escapeAttribute(name)}">
            <span class="settings-swatch-circle" style="background:${hex};${name === current ? `box-shadow:0 0 0 2px #fff,0 0 0 4px ${hex};` : ''}"></span>
            <span class="settings-swatch-name">${escapeHTML(name.charAt(0).toUpperCase() + name.slice(1))}</span>
            <span class="settings-swatch-hex">${escapeHTML(hex)}</span>
            ${name === DEFAULT_THEME ? '<span class="settings-swatch-default">default</span>' : ''}
          </button>
        `).join('')}
      </div>
    </div>
    ${renderTimeSettings()}
    <div class="settings-section">
      <h3>Display Effects</h3>
      <div class="settings-toggle-grid">
        <label class="settings-toggle-row">
          <input type="checkbox" data-display-effect="flicker" ${effects.flicker ? 'checked' : ''}>
          <span>
            <strong>Monitor flicker</strong>
            <small>Subtle CRT brightness drift</small>
          </span>
        </label>
        <label class="settings-toggle-row">
          <input type="checkbox" data-display-effect="syncDrift" ${effects.syncDrift ? 'checked' : ''}>
          <span>
            <strong>Sync drift</strong>
            <small>Occasional horizontal roll line</small>
          </span>
        </label>
      </div>
    </div>
  `;
}

function renderTimeSettings() {
  return `
    <div class="settings-section settings-section-wide">
      <h3>Time & Location</h3>
      <div id="time-settings-panel" class="time-settings-grid">
        <div class="mini-row"><span>Local time</span><strong id="time-local">Loading...</strong></div>
        <div class="mini-row"><span>Timezone</span><strong id="time-timezone">Loading...</strong></div>
        <div class="mini-row"><span>UTC</span><strong id="time-utc">Loading...</strong></div>
      </div>
      <div class="time-settings-form">
        <input id="timezone-input" type="text" placeholder="America/New_York" autocomplete="off">
        <button id="timezone-save-button" class="small-button">Set Timezone</button>
        <button id="timezone-refresh-button" class="small-button">Refresh</button>
      </div>
      <pre id="timezone-output" class="output" hidden></pre>
    </div>
  `;
}

function renderAppCatalog() {
  return `
    <div class="settings-section settings-section-wide">
      <div class="section-title-row">
        <h3>App Catalog</h3>
        <button id="tool-refresh-button" class="small-button">Refresh Updates</button>
      </div>
      <p id="tool-status" class="section-description">Checking installed tools and updates...</p>
      <pre id="tool-output" class="output" hidden></pre>
      <div id="tool-catalog" class="tool-catalog">Loading tool status...</div>
    </div>
  `;
}

function renderMapDrives() {
  return `
    <div class="settings-section settings-section-wide">
      <h3>Map Drives</h3>
      <div class="drive-form">
        <input id="drive-name" type="text" placeholder="share-name">
        <input id="drive-remote" type="text" placeholder="//server/share">
        <input id="drive-mount-point" type="text" placeholder="/mnt/share-name">
        <input id="drive-username" type="text" placeholder="username">
        <input id="drive-password" type="password" placeholder="password">
        <button id="drive-mount-button" class="small-button">Mount CIFS</button>
      </div>
      <p class="section-description">Mounted drives appear at the mount point above. If left blank, the backend uses /mnt/&lt;share-name&gt;; open that path from Files to browse it.</p>
      <pre id="drive-output" class="output" hidden></pre>
    </div>
  `;
}

function bindSettings() {
  bindCustomTitleEditor();
  document.querySelectorAll('[data-theme]').forEach(button => {
    button.addEventListener('click', () => {
      applyTheme(button.dataset.theme);
      renderSection('settings');
    });
  });
  document.querySelectorAll('[data-display-effect]').forEach(input => {
    input.addEventListener('change', () => {
      const effects = loadDisplayEffects();
      effects[input.dataset.displayEffect] = input.checked;
      applyDisplayEffects(effects);
    });
  });
  bindTimeSettings();
}

function bindTimeSettings() {
  document.getElementById('timezone-refresh-button')?.addEventListener('click', loadTimeSettings);
  document.getElementById('timezone-save-button')?.addEventListener('click', saveTimezone);
  loadTimeSettings();
}

async function loadTimeSettings() {
  const output = document.getElementById('timezone-output');
  try {
    const response = await fetch('/api/time-settings', { credentials: 'include' });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `Request failed with ${response.status}`);
    document.getElementById('time-local').textContent = data.localTime || 'unknown';
    document.getElementById('time-timezone').textContent = data.timezone || 'unknown';
    document.getElementById('time-utc').textContent = data.utc || 'unknown';
    const input = document.getElementById('timezone-input');
    if (input && !input.value.trim()) input.value = data.timezone || '';
    if (output) output.hidden = true;
  } catch (error) {
    if (output) {
      output.hidden = false;
      output.textContent = error.message;
    }
  }
}

async function saveTimezone() {
  const output = document.getElementById('timezone-output');
  const timezone = document.getElementById('timezone-input').value.trim();
  output.hidden = false;
  output.textContent = 'Setting timezone...';
  try {
    const result = await postJSON('/api/time-settings', { timezone });
    output.textContent = result.output || 'timezone updated';
    await loadTimeSettings();
  } catch (error) {
    output.textContent = error.message;
  }
}

function bindToolCatalog() {
  document.getElementById('tool-refresh-button')?.addEventListener('click', loadToolCatalog);
  document.getElementById('tool-catalog')?.addEventListener('click', event => {
    const button = event.target.closest('[data-tool-install]');
    if (button) installTool(button.dataset.toolInstall);
  });
  loadToolCatalog();
}

async function loadToolCatalog() {
  const panel = document.getElementById('tool-catalog');
  const status = document.getElementById('tool-status');
  if (!panel) return;
  if (status) status.textContent = 'Checking installed tools and updates...';
  try {
    const response = await fetch('/api/tools', { credentials: 'include' });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `Request failed with ${response.status}`);
    panel.innerHTML = (data.tools || []).map(tool => `
      <section class="tool-row">
        <div>
          <strong>${escapeHTML(tool.label || tool.name)}</strong>
          <p>${escapeHTML(tool.description || '')}</p>
          <div class="tool-meta">
            <span class="${tool.installed ? 'ok-text' : 'warn-text'}">${tool.installed ? escapeHTML(tool.version || 'installed') : 'missing'}</span>
            <span class="${tool.updateAvailable ? 'warn-text' : 'muted'}">${escapeHTML(tool.updateStatus || (tool.installed ? 'No update detected.' : 'not installed'))}</span>
          </div>
        </div>
        <button class="small-button" data-tool-install="${escapeAttribute(tool.name)}">${tool.installed ? 'Update' : 'Install'}</button>
      </section>
    `).join('');
    if (status) status.textContent = 'Tool status current.';
  } catch (error) {
    if (status) status.textContent = error.message;
    if (!panel.children.length) panel.textContent = error.message;
  }
}

async function installTool(tool) {
  const output = document.getElementById('tool-output');
  output.hidden = false;
  output.textContent = `Installing ${tool}...`;
  try {
    const result = await postJSON('/api/tools', { operation: 'install', tool });
    output.textContent = result.output || result.command || 'install command completed';
    await loadToolCatalog();
  } catch (error) {
    output.textContent = error.message;
  }
}

function bindMapDrives() {
  document.getElementById('drive-mount-button')?.addEventListener('click', mountDrive);
}

async function mountDrive() {
  const output = document.getElementById('drive-output');
  output.hidden = false;
  output.textContent = 'Mounting drive...';
  const payload = {
    operation: 'mount-cifs',
    name: document.getElementById('drive-name').value.trim(),
    remote: document.getElementById('drive-remote').value.trim(),
    mountPoint: document.getElementById('drive-mount-point').value.trim(),
    username: document.getElementById('drive-username').value.trim(),
    password: document.getElementById('drive-password').value,
  };
  try {
    const result = await postJSON('/api/drive', payload);
    output.textContent = result.output || 'mounted';
  } catch (error) {
    output.textContent = error.message;
  }
}

function bindSectionActions(section) {
  document.querySelectorAll('[data-action]').forEach(button => {
    button.addEventListener('click', () => runAction(button.dataset.action));
  });
  document.querySelectorAll('[data-nav-updates]').forEach(button => {
    button.addEventListener('click', () => selectSection('updates'));
  });
  document.querySelectorAll('[data-service]').forEach(button => {
    button.addEventListener('click', () => controlService(button.dataset.service, button.dataset.operation));
  });
  if (section === 'files') {
    bindFileBrowser();
  }
  if (section === 'notes') {
    bindNotes();
  }
  if (section === 'projects') {
    bindProjects();
  }
  if (section === 'configs') {
    bindConfigs();
  }
  if (section === 'updates') {
    bindUpdates();
  }
  if (section === 'accounts') {
    bindAccounts();
  }
  if (section === 'github') {
    bindGitHub();
  }
  if (section === 'network') {
    bindNetwork();
  }
  if (section === 'apps') {
    bindToolCatalog();
  }
  if (section === 'drives') {
    bindMapDrives();
  }
  if (section === 'overview') {
    requestAnimationFrame(animateGauges);
  }
  if (section === 'settings') {
    bindSettings();
  }
}

async function runAction(action) {
  const output = document.getElementById('action-output');
  output.hidden = false;
  output.textContent = 'Running...';
  try {
    const result = await postJSON('/api/action', { action });
    output.textContent = stripANSI(result.output || `Exit code ${result.exitCode}`);
    await loadSnapshot();
  } catch (error) {
    output.textContent = stripANSI(error.message);
  }
}

// Streams ccc-self-update output via SSE. The connection drops when systemctl
// restarts the service; any disconnect-after-output is treated as success.
async function runSelfUpdateStream() {
  const output = document.getElementById('self-update-output');
  output.hidden = false;
  output.textContent = 'Connecting...\n';
  let gotLines = false;

  try {
    const response = await fetch('/api/self-update', { method: 'POST', credentials: 'include' });
    if (!response.ok) {
      output.textContent = `Update failed: HTTP ${response.status}`;
      return;
    }
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buf = '';

    outer: while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      const parts = buf.split('\n\n');
      buf = parts.pop();
      for (const part of parts) {
        for (const raw of part.split('\n')) {
          if (!raw.startsWith('data:')) continue;
          let msg;
          try { msg = JSON.parse(raw.slice(5).trim()); } catch { continue; }
          if (msg.line) {
            output.textContent += msg.line + '\n';
            gotLines = true;
          }
          if (msg.status === 'done') { break outer; }
          if (msg.status === 'error') {
            output.textContent += `\nUpdate failed: ${msg.msg || 'unknown error'}`;
            return;
          }
        }
      }
    }
  } catch {
    // Connection dropped — service likely restarted mid-update
  }

  if (!gotLines) {
    output.textContent = 'Failed to start update. Service may be unavailable.';
    return;
  }

  output.textContent += '\nService restarting — reconnecting...';
  monitorReconnect(output);
}

function monitorReconnect(output) {
  if (updatePollTimer) clearInterval(updatePollTimer);
  let attempts = 0;
  updatePollTimer = setInterval(async () => {
    attempts++;
    const data = await fetchWorkstationData();
    if (data) {
      clearInterval(updatePollTimer);
      updatePollTimer = null;
      snapshot = data;
      setSignedIn(true);
      startSnapshotPolling();
      if (output.isConnected) {
        output.textContent += '\nUpdate finished successfully. Reconnected.';
      }
    } else if (attempts >= 60) {
      clearInterval(updatePollTimer);
      updatePollTimer = null;
      if (output.isConnected) {
        output.textContent += '\nTimeout waiting for service restart. Check /var/log/ccc-self-update.log.';
      }
    }
  }, 5000);
}

async function controlService(service, operation) {
  const output = document.getElementById('action-output');
  output.hidden = false;
  output.textContent = `Running ${operation} ${service}...`;
  try {
    const result = await postJSON('/api/service', { service, operation });
    output.textContent = result.output || `Exit code ${result.exitCode}`;
    await loadSnapshot();
    renderSection('services');
  } catch (error) {
    output.textContent = error.message;
  }
}

function bindUpdates() {
  document.querySelectorAll('[data-update-tab]').forEach(button => {
    button.addEventListener('click', () => {
      activeUpdateTab = button.dataset.updateTab === 'os' ? 'os' : 'app';
      renderSection('updates');
    });
  });
  document.getElementById('self-update-btn')?.addEventListener('click', runSelfUpdateStream);
  document.getElementById('os-update-btn')?.addEventListener('click', () => runAction('os-update'));
}

function bindAccounts() {
  document.getElementById('create-account-button').addEventListener('click', createAccount);
  document.querySelectorAll('[data-account-password]').forEach(button => {
    button.addEventListener('click', () => setAccountPassword(button.dataset.accountPassword));
  });
  document.querySelectorAll('[data-account-shell]').forEach(button => {
    button.addEventListener('click', () => setAccountShell(button.dataset.accountShell, button.dataset.currentShell));
  });
  document.querySelectorAll('[data-account-groups]').forEach(button => {
    button.addEventListener('click', () => setAccountGroups(button.dataset.accountGroups, button.dataset.currentGroups));
  });
  document.querySelectorAll('[data-account-delete]').forEach(button => {
    button.addEventListener('click', () => deleteAccount(button.dataset.accountDelete));
  });
}

async function createAccount() {
  const username = document.getElementById('account-username').value.trim();
  const output = document.getElementById('account-output');
  if (!username) {
    output.hidden = false;
    output.textContent = 'Error: username is required';
    return;
  }
  const passwordEl = document.getElementById('account-password');
  const shellEl = document.getElementById('account-shell');
  await runAccountOperation({
    operation: 'create',
    username,
    password: passwordEl ? passwordEl.value : '',
    shell: shellEl ? shellEl.value.trim() || '/bin/bash' : '/bin/bash',
  });
}

async function setAccountPassword(username) {
  const password = prompt(`New password for ${username}`);
  if (!password) return;
  await runAccountOperation({ operation: 'set-password', username, password });
}

async function setAccountShell(username, currentShell) {
  const shell = prompt(`Login shell for ${username}`, currentShell || '/bin/bash');
  if (!shell) return;
  await runAccountOperation({ operation: 'set-shell', username, shell });
}

async function setAccountGroups(username, currentGroups) {
  const groups = prompt(`Supplementary groups for ${username}`, currentGroups || '');
  if (groups === null) return;
  await runAccountOperation({ operation: 'set-groups', username, groups });
}

async function deleteAccount(username) {
  if (!confirm(`Delete account ${username} and its home directory?`)) return;
  await runAccountOperation({ operation: 'delete', username });
}

async function runAccountOperation(payload) {
  const output = document.getElementById('account-output');
  if (!output) return;
  output.hidden = false;
  output.textContent = 'Running...';
  try {
    const result = await postJSON('/api/account', payload);
    output.textContent = result.output || 'account updated';
    if (payload.operation === 'create') {
      const usernameEl = document.getElementById('account-username');
      const passwordEl = document.getElementById('account-password');
      const shellEl = document.getElementById('account-shell');
      if (usernameEl) usernameEl.value = '';
      if (passwordEl) passwordEl.value = '';
      if (shellEl) shellEl.value = '/bin/bash';
    }
    await loadSnapshot();
    renderSection('accounts');
  } catch (error) {
    output.textContent = error.message;
  }
}

function bindGitHub() {
  loadGitHubStatus();
  document.getElementById('github-generate-btn').addEventListener('click', generateGitHubKey);
  document.getElementById('github-test-btn').addEventListener('click', testGitHubConnection);
}

async function loadGitHubStatus() {
  const panel = document.getElementById('github-key-panel');
  if (!panel) return;
  try {
    const response = await fetch('/api/github', { credentials: 'include' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const status = await response.json();
    if (status.keyExists) {
      panel.innerHTML = `
        <dl class="facts">
          <dt>Key path</dt><dd>${escapeHTML(status.keyPath)}</dd>
          <dt>Public key</dt><dd><code class="pubkey">${escapeHTML(status.publicKey)}</code></dd>
        </dl>
        <p class="section-description">Copy the public key above, then <a href="https://github.com/settings/ssh/new" target="_blank" rel="noopener">add it to GitHub</a>.</p>
        <button class="small-button" id="github-copy-btn">Copy Public Key</button>
      `;
      document.getElementById('github-copy-btn')?.addEventListener('click', async () => {
        const btn = document.getElementById('github-copy-btn');
        const copied = await copyTextToClipboard(status.publicKey);
        showCopyButtonState(btn, copied ? 'Copied!' : 'Copy Failed');
      });
    } else {
      panel.innerHTML = `<p class="muted">No SSH key found at <code>${escapeHTML(status.keyPath)}</code>. Generate one below.</p>`;
    }
  } catch (err) {
    panel.innerHTML = `<p class="error-text">Failed to load SSH key status: ${escapeHTML(err.message)}</p>`;
  }
}

async function copyTextToClipboard(text) {
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      return fallbackCopyText(text);
    }
  }
  return fallbackCopyText(text);
}

function fallbackCopyText(text) {
  const el = document.createElement('textarea');
  el.value = text;
  el.setAttribute('readonly', '');
  Object.assign(el.style, {
    position: 'fixed',
    top: '0',
    left: '0',
    width: '1px',
    height: '1px',
    opacity: '0',
  });
  document.body.appendChild(el);
  el.focus();
  el.select();
  el.setSelectionRange(0, el.value.length);
  try {
    return document.execCommand('copy');
  } catch {
    return false;
  } finally {
    document.body.removeChild(el);
  }
}

function showCopyButtonState(button, label) {
  if (!button) return;
  button.textContent = label;
  setTimeout(() => { button.textContent = 'Copy Public Key'; }, 2000);
}

async function generateGitHubKey() {
  const output = document.getElementById('github-output');
  output.hidden = false;
  output.textContent = 'Generating SSH key...';
  try {
    const result = await postJSON('/api/github', { action: 'generate-key' });
    output.textContent = result.exitCode === 0
      ? `Key generated.\n\nPublic key:\n${result.output}`
      : `Failed:\n${result.output}`;
    loadGitHubStatus();
  } catch (err) {
    output.textContent = `Error: ${err.message}`;
  }
}

async function testGitHubConnection() {
  const output = document.getElementById('github-output');
  output.hidden = false;
  output.textContent = 'Testing connection to github.com...';
  try {
    const result = await postJSON('/api/github', { action: 'test-connection' });
    output.textContent = result.output || '(no output)';
  } catch (err) {
    output.textContent = `Error: ${err.message}`;
  }
}

function bindNetwork() {
  drawNetworkGraph();
}

function stopNetworkGraph() {
  if (networkPollTimer) {
    clearInterval(networkPollTimer);
    networkPollTimer = null;
  }
}

async function pollNetworkActivity() {
  const rate = document.getElementById('network-rate');
  try {
    const response = await fetch('/api/network-activity', { credentials: 'include' });
    const sample = await response.json();
    if (!response.ok) throw new Error(sample.error || `Request failed with ${response.status}`);
    updateNetworkGraph(sample);
  } catch (error) {
    if (rate) rate.textContent = `Network activity unavailable: ${error.message}`;
  }
}

function updateNetworkGraph(sample) {
  const now = Date.now();
  const interfaces = sample.interfaces || [];
  const totals = interfaces.reduce((sum, item) => ({
    rxBytes: sum.rxBytes + (item.rxBytes || 0),
    txBytes: sum.txBytes + (item.txBytes || 0),
  }), { rxBytes: 0, txBytes: 0 });
  if (!lastNetworkSample) {
    lastNetworkSample = { time: now, ...totals };
    return;
  }
  const seconds = Math.max(1, (now - lastNetworkSample.time) / 1000);
  const rxRate = Math.max(0, (totals.rxBytes - lastNetworkSample.rxBytes) / seconds);
  const txRate = Math.max(0, (totals.txBytes - lastNetworkSample.txBytes) / seconds);
  lastNetworkSample = { time: now, ...totals };
  networkHistory.push({ rxRate, txRate });
  networkHistory = networkHistory.slice(-60);
  const rate = document.getElementById('network-rate');
  if (rate) rate.textContent = `Down ${formatBytes(rxRate)}/s · Up ${formatBytes(txRate)}/s`;
  drawNetworkGraph();
}

function drawNetworkGraph() {
  const canvas = document.getElementById('network-graph');
  if (!canvas?.getContext) return;
  const ctx = canvas.getContext('2d');
  const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#4ade80';
  const width = canvas.width;
  const height = canvas.height;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = '#020810';
  ctx.fillRect(0, 0, width, height);
  const maxRate = Math.max(1, ...networkHistory.flatMap(point => [point.rxRate, point.txRate]));
  drawNetworkSeries(ctx, width, height, maxRate, 'rxRate', accent);
  drawNetworkSeries(ctx, width, height, maxRate, 'txRate', '#34d399');
}

function drawNetworkSeries(ctx, width, height, maxRate, key, color) {
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.beginPath();
  networkHistory.forEach((point, index) => {
    const x = networkHistory.length <= 1 ? 0 : (index / (networkHistory.length - 1)) * width;
    const y = height - ((point[key] || 0) / maxRate) * (height - 16) - 8;
    if (index === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  });
  ctx.stroke();
}

function bindFileBrowser() {
  document.getElementById('browse-button').addEventListener('click', () => {
    filePath = document.getElementById('file-path').value;
    loadFiles(filePath);
  });
  document.getElementById('file-home-button')?.addEventListener('click', () => {
    filePath = '/home';
    loadFiles(filePath);
  });
  document.getElementById('file-projects-button')?.addEventListener('click', () => {
    filePath = snapshot.projects?.[0]?.path ? directoryName(snapshot.projects[0].path) : '/home';
    loadFiles(filePath);
  });
  document.getElementById('file-refresh-button')?.addEventListener('click', () => loadFiles(filePath));
  document.querySelectorAll('[data-file-breadcrumb]').forEach(button => {
    button.addEventListener('click', () => {
      filePath = button.dataset.fileBreadcrumb;
      loadFiles(filePath);
    });
  });
  document.getElementById('parent-button').addEventListener('click', () => {
    const parts = filePath.split('/').filter(Boolean);
    parts.pop();
    filePath = `/${parts.join('/')}`;
    if (filePath === '/') {
      filePath = '/';
    }
    document.getElementById('file-path').value = filePath;
    loadFiles(filePath);
  });
  document.getElementById('save-file-button').addEventListener('click', saveCurrentFile);
  document.getElementById('file-new-file-button')?.addEventListener('click', () => createFileEntry('file'));
  document.getElementById('file-new-folder-button')?.addEventListener('click', () => createFileEntry('dir'));
  document.getElementById('file-rename-button')?.addEventListener('click', renameCurrentFile);
  document.getElementById('file-copy-button')?.addEventListener('click', copyCurrentFile);
  document.getElementById('file-chmod-button')?.addEventListener('click', chmodCurrentFile);
  document.getElementById('file-delete-button')?.addEventListener('click', deleteCurrentFile);
  document.getElementById('file-upload-input')?.addEventListener('change', uploadCurrentDirectory);
  document.getElementById('file-download-button')?.addEventListener('click', downloadCurrentFile);
  loadFiles(filePath);
}

async function loadFiles(path) {
  const list = document.getElementById('file-list');
  const count = document.getElementById('file-count');
  list.textContent = 'Loading...';
  if (count) count.textContent = 'Loading...';
  try {
    const response = await fetch(`/api/files?path=${encodeURIComponent(path)}`, { credentials: 'include' });
    const data = await response.json();
    if (!response.ok) {
      throw new Error(data.error || `Request failed with ${response.status}`);
    }
    filePath = data.path;
    selectedFilePath = '';
    updateSelectedFileDetail();
    document.getElementById('file-path').value = data.path;
    document.getElementById('file-breadcrumbs').innerHTML = renderFileBreadcrumbs(data.path);
    document.querySelectorAll('[data-file-breadcrumb]').forEach(button => {
      button.addEventListener('click', () => {
        filePath = button.dataset.fileBreadcrumb;
        loadFiles(filePath);
      });
    });
    const entries = data.entries || [];
    if (count) count.textContent = `${entries.length} item${entries.length === 1 ? '' : 's'}`;
    list.innerHTML = entries.map(renderFileEntry).join('') || '<p class="file-empty">No files found.</p>';
    list.querySelectorAll('.file-entry').forEach(button => {
      button.addEventListener('click', () => {
        if (button.dataset.type === 'dir') {
          filePath = button.dataset.path;
          loadFiles(filePath);
        } else {
          selectFileEntry(button);
        }
      });
    });
  } catch (error) {
    list.textContent = error.message;
    if (count) count.textContent = 'Unavailable';
  }
}

function renderFileEntry(entry) {
  const isDir = entry.type === 'dir';
  return `
    <button class="file-entry ${isDir ? 'directory' : 'regular-file'}" data-path="${escapeAttribute(entry.path)}" data-type="${escapeAttribute(entry.type)}" data-name="${escapeAttribute(entry.name)}" data-size="${escapeAttribute(formatBytes(entry.size))}" data-mtime="${escapeAttribute(entry.mtime || '')}" data-mode="${escapeAttribute(entry.mode || '')}">
      <span class="file-entry-icon">${isDir ? 'DIR' : 'FILE'}</span>
      <strong>${escapeHTML(entry.name)}</strong>
      <small>${isDir ? '-' : escapeHTML(formatBytes(entry.size))}</small>
      <small>${escapeHTML(entry.mtime || '')}</small>
    </button>
  `;
}

function selectFileEntry(button) {
  selectedFilePath = button.dataset.path;
  currentFile = selectedFilePath;
  document.querySelectorAll('.file-entry').forEach(entry => {
    entry.classList.toggle('selected', entry === button);
  });
  document.getElementById('current-file').value = selectedFilePath;
  updateSelectedFileDetail(button);
  openFile(selectedFilePath);
}

function updateSelectedFileDetail(button) {
  const detail = document.getElementById('file-selected-detail');
  if (!detail) return;
  if (!button) {
    detail.textContent = 'No file selected';
    return;
  }
  detail.textContent = `${button.dataset.name || 'Selected'} · ${button.dataset.size || '0 B'} · ${button.dataset.mode || 'mode unknown'} · ${button.dataset.mtime || 'no timestamp'}`;
}

async function openFile(path) {
  const output = document.getElementById('file-output');
  output.hidden = true;
  try {
    const response = await fetch(`/api/file?path=${encodeURIComponent(path)}`, { credentials: 'include' });
    const data = await response.json();
    if (!response.ok) {
      throw new Error(data.error || `Request failed with ${response.status}`);
    }
    currentFile = data.path;
    document.getElementById('current-file').value = data.path;
    document.getElementById('file-editor').value = data.content;
  } catch (error) {
    output.hidden = false;
    output.textContent = error.message;
  }
}

async function saveCurrentFile() {
  const output = document.getElementById('file-output');
  const path = document.getElementById('current-file').value;
  const content = document.getElementById('file-editor').value;
  output.hidden = false;
  output.textContent = 'Saving...';
  try {
    const result = await postJSON('/api/file', { path, content }, 'PUT');
    output.textContent = result.status || 'saved';
    currentFile = path;
    await loadFiles(filePath);
  } catch (error) {
    output.textContent = error.message;
  }
}

async function uploadCurrentDirectory(event) {
  const input = event.target;
  const output = document.getElementById('file-output');
  const file = input.files?.[0];
  if (!file) return;
  const form = new FormData();
  form.append('file', file);
  output.hidden = false;
  output.textContent = 'Uploading...';
  try {
    const response = await fetch(`/api/file-upload?path=${encodeURIComponent(filePath)}`, {
      method: 'POST',
      body: form,
      credentials: 'include',
    });
    const result = await response.json();
    if (!response.ok) {
      throw new Error(result.error || `Request failed with ${response.status}`);
    }
    output.textContent = `Uploaded ${result.file?.path || file.name}`;
    await loadFiles(filePath);
  } catch (error) {
    output.textContent = error.message;
  } finally {
    input.value = '';
  }
}

function downloadCurrentFile() {
  const path = selectedFilePath || document.getElementById('current-file').value;
  const output = document.getElementById('file-output');
  if (!path) {
    output.hidden = false;
    output.textContent = 'Select a file to download.';
    return;
  }
  window.location.href = `/api/file-download?path=${encodeURIComponent(path)}`;
}

async function createFileEntry(kind) {
  const name = prompt(kind === 'dir' ? 'Folder name' : 'File name');
  if (!name) return;
  const path = `${filePath.replace(/\/+$/, '')}/${name}`;
  const output = document.getElementById('file-output');
  output.hidden = false;
  output.textContent = 'Creating...';
  try {
    const result = await postJSON('/api/file-op', { operation: 'create', path, kind });
    output.textContent = result.output || 'created';
    await loadFiles(filePath);
  } catch (error) {
    output.textContent = error.message;
  }
}

async function renameCurrentFile() {
  const path = selectedFilePath || document.getElementById('current-file').value;
  if (!path) return;
  const target = prompt('New path', path);
  if (!target || target === path) return;
  const output = document.getElementById('file-output');
  output.hidden = false;
  output.textContent = 'Renaming...';
  try {
    const result = await postJSON('/api/file-op', { operation: 'rename', path, target });
    output.textContent = result.output || 'renamed';
    currentFile = target;
    selectedFilePath = target;
    document.getElementById('current-file').value = target;
    await loadFiles(filePath);
  } catch (error) {
    output.textContent = error.message;
  }
}

async function copyCurrentFile() {
  const path = selectedFilePath || document.getElementById('current-file').value;
  if (!path) return;
  const target = prompt('Copy to path', `${path}.copy`);
  if (!target || target === path) return;
  const output = document.getElementById('file-output');
  output.hidden = false;
  output.textContent = 'Copying...';
  try {
    const result = await postJSON('/api/file-op', { operation: 'copy', path, target });
    output.textContent = result.output || 'copied';
    await loadFiles(filePath);
  } catch (error) {
    output.textContent = error.message;
  }
}

async function chmodCurrentFile() {
  const path = selectedFilePath || document.getElementById('current-file').value;
  if (!path) return;
  const mode = prompt('Permissions mode', '644');
  if (!mode) return;
  const output = document.getElementById('file-output');
  output.hidden = false;
  output.textContent = 'Updating permissions...';
  try {
    const result = await postJSON('/api/file-op', { operation: 'chmod', path, mode });
    output.textContent = result.output || 'permissions updated';
    await loadFiles(filePath);
  } catch (error) {
    output.textContent = error.message;
  }
}

async function deleteCurrentFile() {
  const path = selectedFilePath || document.getElementById('current-file').value;
  if (!path || !confirm(`Delete ${path}?`)) return;
  const output = document.getElementById('file-output');
  output.hidden = false;
  output.textContent = 'Deleting...';
  try {
    const result = await postJSON('/api/file-op', { operation: 'delete', path });
    output.textContent = result.output || 'deleted';
    currentFile = '';
    selectedFilePath = '';
    document.getElementById('current-file').value = '';
    document.getElementById('file-editor').value = '';
    await loadFiles(filePath);
  } catch (error) {
    output.textContent = error.message;
  }
}

function bindTerminal() {
  applyTerminalHeight();
  bindTerminalHeightControls();
  document.getElementById('terminal-new-tab').addEventListener('click', createTerminalTab);
  document.querySelectorAll('[data-terminal-tab]').forEach(button => {
    button.addEventListener('click', () => switchTerminalTab(Number(button.dataset.terminalTab)));
  });
  document.getElementById('terminal-connect').addEventListener('click', connectTerminal);
  document.getElementById('terminal-disconnect').addEventListener('click', disconnectTerminal);
  document.getElementById('terminal-tmux').addEventListener('click', () => sendTerminalInput('tmux\n'));
  document.querySelectorAll('[data-tmux-command]').forEach(button => {
    button.addEventListener('click', () => sendTerminalInput(`${button.dataset.tmuxCommand}\n`));
  });
  document.getElementById('terminal-raw-send').addEventListener('click', () => {
    const input = document.getElementById('terminal-raw-input');
    sendTerminalInput(`${input.value}\n`);
    input.value = '';
  });
  connectTerminal();
}

function bindTerminalHeightControls() {
  const slider = document.getElementById('terminal-height-slider');
  if (!slider) return;
  slider.addEventListener('input', () => {
    applyTerminalHeight(slider.value);
    resizeTerminal();
  });
}

function loadTerminalHeight() {
  const saved = Number(localStorage.getItem(TERMINAL_HEIGHT_STORAGE_KEY));
  if (Number.isFinite(saved)) {
    return Math.max(360, Math.min(900, saved));
  }
  return 560;
}

function applyTerminalHeight(value = loadTerminalHeight()) {
  const height = Math.max(360, Math.min(900, Number(value) || 560));
  document.documentElement.style.setProperty('--terminal-height', `${height}px`);
  localStorage.setItem(TERMINAL_HEIGHT_STORAGE_KEY, String(height));
  const label = document.getElementById('terminal-height-value');
  if (label) label.textContent = `${height}px`;
}

function connectTerminal() {
  const tab = activeTerminalTab();
  if (!tab) return;
  if (tab.socket && tab.socket.readyState === WebSocket.OPEN) return;
  if (tab.socket && tab.socket.readyState === WebSocket.CONNECTING) return;
  resetTerminalConnection(tab, 'Connecting...', false);
  const status = document.getElementById('terminal-status');
  status.textContent = 'Connecting...';
  tab.status = 'Connecting...';
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
  const socket = new WebSocket(`${scheme}://${location.host}/api/pty`);
  tab.socket = socket;
  terminalSocket = socket;
  socket.addEventListener('open', () => {
    if (tab.socket !== socket) {
      socket.close();
      return;
    }
    status.textContent = 'Connected';
    tab.status = 'Connected';
    if (window.Terminal) {
      const pane = activeTerminalPane();
      pane.innerHTML = '';
      document.getElementById('terminal-fallback').hidden = true;
      tab.terminal = new window.Terminal({ cursorBlink: true, fontSize: 13, convertEol: true });
      terminal = tab.terminal;
      tab.terminal.open(pane);
      tab.terminal.focus();
      tab.terminal.onData(sendTerminalInput);
      resizeTerminal();
      window.addEventListener('resize', resizeTerminal);
    } else {
      document.getElementById('terminal-fallback').hidden = false;
      activeTerminalPane().textContent = 'xterm.js unavailable; using raw terminal fallback.';
    }
  });
  socket.addEventListener('message', event => {
    if (tab.socket !== socket) return;
    if (tab.terminal) {
      tab.terminal.write(event.data);
    } else {
      tab.rawTerminalBuffer += event.data;
      rawTerminalBuffer = tab.rawTerminalBuffer;
      const output = document.getElementById('terminal-raw-output');
      output.textContent = tab.rawTerminalBuffer;
      output.scrollTop = output.scrollHeight;
    }
  });
  socket.addEventListener('error', () => {
    if (tab.socket === socket) {
      tab.status = 'Connection error';
      status.textContent = 'Connection error';
    }
  });
  socket.addEventListener('close', () => {
    if (tab.socket === socket) {
      resetTerminalConnection(tab, 'Disconnected', false);
    }
  });
}

function disconnectTerminal() {
  const tab = activeTerminalTab();
  if (tab) resetTerminalConnection(tab, 'Disconnected', true);
}

function stopTerminalSessions() {
  terminalTabs.forEach(tab => resetTerminalConnection(tab, 'Disconnected', true));
}

function resetTerminalConnection(tab = activeTerminalTab(), message = 'Disconnected', closeSocket = true) {
  if (!tab) return;
  const socket = tab.socket;
  tab.socket = null;
  if (terminalSocket === socket) terminalSocket = null;
  if (closeSocket && socket && socket.readyState !== WebSocket.CLOSED) {
    socket.close();
  }
  window.removeEventListener('resize', resizeTerminal);
  const disposedTerminal = tab.terminal;
  if (tab.terminal) {
    tab.terminal.dispose();
    tab.terminal = null;
  }
  tab.rawTerminalBuffer = '';
  tab.status = message;
  if (terminal === disposedTerminal) terminal = null;
  const pane = document.getElementById(`terminal-pane-${tab.id}`);
  if (pane && tab.id === activeTerminalTabId) pane.innerHTML = '';
  const status = document.getElementById('terminal-status');
  if (status && tab.id === activeTerminalTabId) status.textContent = message;
}

function sendTerminalInput(data) {
  const tab = activeTerminalTab();
  if (!tab?.socket || tab.socket.readyState !== WebSocket.OPEN) return;
  tab.socket.send(JSON.stringify({ type: 'input', data }));
}

function resizeTerminal() {
  const tab = activeTerminalTab();
  if (!tab?.socket || tab.socket.readyState !== WebSocket.OPEN || !tab.terminal) return;
  fitTerminalToPane(tab);
  tab.socket.send(JSON.stringify({ type: 'resize', cols: tab.terminal.cols || 100, rows: tab.terminal.rows || 30 }));
}

function fitTerminalToPane(tab = activeTerminalTab()) {
  if (!tab?.terminal) return;
  const pane = document.getElementById(`terminal-pane-${tab.id}`);
  if (!pane) return;
  const sample = pane.querySelector('.xterm-rows span');
  const cellWidth = sample?.getBoundingClientRect().width || 8;
  const cellHeight = sample?.getBoundingClientRect().height || 17;
  const cols = Math.max(40, Math.floor((pane.clientWidth - 16) / cellWidth));
  const rows = Math.max(10, Math.floor((pane.clientHeight - 16) / cellHeight));
  if (cols !== tab.terminal.cols || rows !== tab.terminal.rows) {
    tab.terminal.resize(cols, rows);
  }
}

function ensureTerminalTab() {
  if (!terminalTabs.length) {
    terminalTabs.push(newTerminalTab());
  }
  if (!activeTerminalTabId) {
    activeTerminalTabId = terminalTabs[0].id;
  }
}

function newTerminalTab() {
  const id = nextTerminalTabId++;
  return { id, name: `Shell ${id}`, socket: null, terminal: null, rawTerminalBuffer: '', status: 'Disconnected' };
}

function activeTerminalTab() {
  return terminalTabs.find(tab => tab.id === activeTerminalTabId) || null;
}

function activeTerminalPane() {
  return document.getElementById(`terminal-pane-${activeTerminalTabId}`);
}

function createTerminalTab() {
  const tab = newTerminalTab();
  terminalTabs.push(tab);
  const list = document.getElementById('terminal-tab-list');
  const button = document.createElement('button');
  button.className = 'terminal-tab';
  button.dataset.terminalTab = String(tab.id);
  button.textContent = tab.name;
  button.addEventListener('click', () => switchTerminalTab(tab.id));
  list.appendChild(button);
  const panes = document.getElementById('terminal-panes');
  const pane = document.createElement('div');
  pane.id = `terminal-pane-${tab.id}`;
  pane.className = 'terminal-pane';
  pane.hidden = true;
  panes.appendChild(pane);
  switchTerminalTab(tab.id);
  connectTerminal();
}

function switchTerminalTab(id) {
  if (!terminalTabs.some(tab => tab.id === id)) return;
  activeTerminalTabId = id;
  document.querySelectorAll('.terminal-tab').forEach(button => {
    button.classList.toggle('active', Number(button.dataset.terminalTab) === id);
  });
  document.querySelectorAll('.terminal-pane').forEach(pane => {
    pane.hidden = pane.id !== `terminal-pane-${id}`;
  });
  const tab = activeTerminalTab();
  const status = document.getElementById('terminal-status');
  if (status) status.textContent = tab?.status || 'Disconnected';
  if (tab?.terminal) tab.terminal.focus();
}

function bindConfigs() {
  document.querySelectorAll('[data-config-edit]').forEach(button => {
    button.addEventListener('click', () => showConfigEditor(button.dataset.configEdit));
  });
  const saveBtn = document.getElementById('config-editor-save');
  const cancelBtn = document.getElementById('config-editor-cancel');
  if (saveBtn) saveBtn.addEventListener('click', saveConfigFile);
  if (cancelBtn) cancelBtn.addEventListener('click', hideConfigEditor);
}

async function showConfigEditor(path) {
  const panel = document.getElementById('config-editor-panel');
  const title = document.getElementById('config-editor-title');
  const textarea = document.getElementById('config-editor-textarea');
  const output = document.getElementById('config-editor-output');
  if (!panel) return;
  panel.hidden = false;
  output.hidden = true;
  textarea.value = '';
  title.textContent = path;
  textarea.dataset.path = path;
  textarea.placeholder = 'Loading...';
  try {
    const response = await fetch(`/api/file?path=${encodeURIComponent(path)}`, { credentials: 'include' });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `Request failed with ${response.status}`);
    textarea.value = data.content;
    textarea.placeholder = '';
    textarea.focus();
  } catch (error) {
    textarea.placeholder = '';
    output.hidden = false;
    output.textContent = error.message;
  }
}

async function saveConfigFile() {
  const textarea = document.getElementById('config-editor-textarea');
  const output = document.getElementById('config-editor-output');
  const saveBtn = document.getElementById('config-editor-save');
  const path = textarea?.dataset.path;
  if (!path) return;
  output.hidden = false;
  output.textContent = 'Saving...';
  if (saveBtn) saveBtn.disabled = true;
  try {
    await postJSON('/api/file', { path, content: textarea.value }, 'PUT');
    output.textContent = 'Saved.';
    await loadSnapshot();
  } catch (error) {
    output.textContent = error.message;
  } finally {
    if (saveBtn) saveBtn.disabled = false;
  }
}

function hideConfigEditor() {
  const panel = document.getElementById('config-editor-panel');
  if (panel) panel.hidden = true;
}

function openAgentConfig(path) {
  if (!path) return;
  filePath = directoryName(path);
  currentFile = path;
  selectSection('files');
  openFile(path);
}

function bindProjects() {
  document.getElementById('create-project-button').addEventListener('click', createProject);
  document.getElementById('add-existing-project-button').addEventListener('click', addExistingProject);
  document.querySelectorAll('[data-project-browse]').forEach(button => {
    button.addEventListener('click', () => {
      filePath = button.dataset.projectBrowse;
      selectSection('files');
    });
  });
  document.querySelectorAll('[data-project-open]').forEach(button => {
    button.addEventListener('click', () => {
      window.open(`${location.protocol}//${location.hostname}:8080/?folder=${encodeURIComponent(button.dataset.projectOpen)}`, '_blank');
    });
  });
  document.querySelectorAll('[data-project-rename]').forEach(button => {
    button.addEventListener('click', () => renameProject(button.dataset.projectRename));
  });
  document.querySelectorAll('[data-project-delete]').forEach(button => {
    button.addEventListener('click', () => deleteProject(button.dataset.projectDelete));
  });
}

async function createProject() {
  const output = document.getElementById('project-output');
  const name = document.getElementById('project-name').value.trim();
  const template = document.getElementById('project-template').value;
  output.hidden = false;
  output.textContent = 'Creating...';
  try {
    const result = await postJSON('/api/project', { operation: 'create', name, template });
    output.textContent = result.output || 'created';
    await refresh();
  } catch (error) {
    output.textContent = error.message;
  }
}

async function addExistingProject() {
  const output = document.getElementById('project-output');
  const name = document.getElementById('existing-project-name').value.trim();
  const path = document.getElementById('existing-project-path').value.trim();
  output.hidden = false;
  output.textContent = 'Adding existing directory...';
  try {
    const result = await postJSON('/api/project', { operation: 'add-existing', name, path });
    output.textContent = result.output || 'added';
    await refresh();
  } catch (error) {
    output.textContent = error.message;
  }
}

async function renameProject(name) {
  const newName = prompt('New project name', name);
  if (!newName || newName === name) return;
  await runProjectOperation({ operation: 'rename', name, newName });
}

async function deleteProject(name) {
  if (!confirm(`Delete project ${name}?`)) return;
  await runProjectOperation({ operation: 'delete', name });
}

async function runProjectOperation(payload) {
  const output = document.getElementById('project-output');
  output.hidden = false;
  output.textContent = 'Running...';
  try {
    const result = await postJSON('/api/project', payload);
    output.textContent = result.output || 'ok';
    await refresh();
  } catch (error) {
    output.textContent = error.message;
  }
}

function bindNotes() {
  document.getElementById('notes-new-button')?.addEventListener('click', createNote);
  document.getElementById('notes-refresh-button')?.addEventListener('click', loadNotes);
  document.getElementById('notes-save-button')?.addEventListener('click', saveActiveNote);
  document.getElementById('notes-delete-button')?.addEventListener('click', deleteActiveNote);
  document.getElementById('notes-title-input')?.addEventListener('input', markNotesDirty);
  document.getElementById('notes-editor')?.addEventListener('input', markNotesDirty);
  loadNotes();
}

async function loadNotes() {
  const list = document.getElementById('notes-list');
  if (list) list.textContent = 'Loading notes...';
  try {
    const response = await fetch('/api/notes', { credentials: 'include' });
    if (!response.ok) throw new Error(await response.text() || `Request failed with ${response.status}`);
    const data = await response.json();
    notesCache = data.notes || [];
    if (activeNoteId && !notesCache.some(note => note.id === activeNoteId)) {
      activeNoteId = '';
    }
    if (!activeNoteId && notesCache.length) {
      activeNoteId = notesCache[0].id;
    }
    notesDirty = false;
    renderNotesList();
    showActiveNote();
  } catch (error) {
    if (list) list.textContent = `Unable to load notes: ${error.message}`;
  }
}

function renderNotesList() {
  const list = document.getElementById('notes-list');
  if (!list) return;
  if (!notesCache.length) {
    list.innerHTML = '<p class="muted">No notes yet.</p>';
    return;
  }
  list.innerHTML = notesCache.map(note => `
    <button class="note-row${note.id === activeNoteId ? ' active' : ''}" data-note-id="${escapeAttribute(note.id)}">
      <strong>${escapeHTML(note.title || 'Untitled')}</strong>
      <span>${escapeHTML(formatNoteDate(note.updatedAt))}</span>
    </button>
  `).join('');
  list.querySelectorAll('[data-note-id]').forEach(button => {
    button.addEventListener('click', () => selectNote(button.dataset.noteId));
  });
}

function selectNote(id) {
  if (id === activeNoteId) return;
  if (!confirmDiscardNotes()) return;
  activeNoteId = id;
  notesDirty = false;
  renderNotesList();
  showActiveNote();
}

function showActiveNote() {
  const title = document.getElementById('notes-title-input');
  const editor = document.getElementById('notes-editor');
  const status = document.getElementById('notes-status');
  const updated = document.getElementById('notes-updated');
  const selected = notesCache.find(note => note.id === activeNoteId);
  if (!title || !editor || !status || !updated) return;
  title.disabled = !selected;
  editor.disabled = !selected;
  document.getElementById('notes-save-button').disabled = !selected;
  document.getElementById('notes-delete-button').disabled = !selected;
  title.value = selected?.title || '';
  editor.value = selected?.content || '';
  status.textContent = selected ? 'Saved.' : 'Select or create a note.';
  updated.textContent = selected?.updatedAt ? `Updated ${formatNoteDate(selected.updatedAt)}` : '';
}

function markNotesDirty() {
  notesDirty = true;
  setNotesStatus('Unsaved changes.');
}

function confirmDiscardNotes() {
  return !notesDirty || window.confirm('Discard unsaved note changes?');
}

async function createNote() {
  if (!confirmDiscardNotes()) return;
  try {
    const note = await postJSON('/api/notes', { title: 'New note', content: '' });
    activeNoteId = note.id;
    await loadNotes();
    document.getElementById('notes-title-input')?.focus();
  } catch (error) {
    setNotesStatus(error.message);
  }
}

async function saveActiveNote() {
  const title = document.getElementById('notes-title-input');
  const editor = document.getElementById('notes-editor');
  if (!activeNoteId || !title || !editor) return;
  try {
    const note = await postJSON('/api/notes', {
      id: activeNoteId,
      title: title.value,
      content: editor.value,
    }, 'PUT');
    activeNoteId = note.id;
    notesDirty = false;
    await loadNotes();
    setNotesStatus('Saved.');
  } catch (error) {
    setNotesStatus(error.message);
  }
}

async function deleteActiveNote() {
  if (!activeNoteId) return;
  if (!window.confirm('Delete this note?')) return;
  try {
    const response = await fetch(`/api/notes?id=${encodeURIComponent(activeNoteId)}`, {
      method: 'DELETE',
      credentials: 'include',
    });
    if (!response.ok) {
      let message = await response.text();
      try { message = JSON.parse(message).error || message; } catch {}
      throw new Error(message || `Request failed with ${response.status}`);
    }
    activeNoteId = '';
    notesDirty = false;
    await loadNotes();
    setNotesStatus('Deleted.');
  } catch (error) {
    setNotesStatus(error.message);
  }
}

function setNotesStatus(message) {
  const status = document.getElementById('notes-status');
  if (status) status.textContent = message;
}

function formatNoteDate(value) {
  if (!value) return 'never';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

async function postJSON(url, body, method = 'POST') {
  const response = await fetch(url, {
    method,
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

function statusTile(label, value) {
  return `
    <div class="status-tile">
      <span>${escapeHTML(label)}</span>
      <strong>${escapeHTML(value)}</strong>
    </div>
  `;
}

function updateStatusBadge(statusText, logText) {
  if (logText.includes('Self-update successful') || statusText.includes('Up to date')) return 'Current';
  if (logText.includes('Update script exited with errors') || logText.includes('Download failed')) return 'Update failed';
  if (statusText.includes('commit(s) behind') || statusText.includes('Update available')) return 'Updates available';
  if (statusText.includes('installed commit is not recorded') || statusText.includes('Installed: not recorded')) return 'Not recorded';
  return 'Unknown';
}

function updateBadgeClass(label) {
  if (label === 'Current') return 'ok';
  if (label === 'Update failed') return 'fail';
  if (label === 'Updates available' || label === 'Not recorded') return 'warn';
  return '';
}

function updatePanelText(statusText, logText) {
  const successLine = logText.split('\n').find(line => line.includes('Self-update successful'));
  return [successLine, statusText].filter(Boolean).join('\n');
}

function formatOSPackageStatus(text) {
  const lines = stripANSI(text)
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
    .filter(line => line !== 'Listing...');
  if (!lines.length) {
    return 'No OS package updates available.';
  }
  return lines.join('\n');
}

function gauge(label, value, detail, key = '') {
  const percent = clampPercent(value);
  return `
    <div class="gauge-card" data-gauge-card="${escapeAttribute(key)}">
      <div class="gauge" style="--value:${percent}">
        <div class="gauge-inner">
          <strong data-gauge-value="${escapeAttribute(key)}">${Number.isFinite(percent) ? percent.toFixed(0) : 0}%</strong>
          <span>${escapeHTML(label)}</span>
        </div>
      </div>
      <p data-gauge-detail="${escapeAttribute(key)}">${escapeHTML(detail || '')}</p>
    </div>
  `;
}

function updateOverviewLive() {
  if (!snapshot?.overview) return;
  const data = snapshot.overview;
  updateGauge('cpu', loadPercent(data.load?.one, data.cpu?.cores), `${formatLoad(data.load)} · ${data.cpu?.cores || 1} cores`);
  updateGauge('memory', data.memory?.usedPercent, `${formatBytes(usedBytes(data.memory))} / ${formatBytes(data.memory?.totalBytes || 0)}`);
  updateGauge('disk', data.disk?.usedPercent, `${formatBytes(data.disk?.usedBytes || 0)} / ${formatBytes(data.disk?.totalBytes || 0)} on ${data.disk?.mount || '/'}`);
}

function updateGauge(key, value, detail) {
  const percent = clampPercent(value);
  const card = document.querySelector(`[data-gauge-card="${key}"] .gauge`);
  const label = document.querySelector(`[data-gauge-value="${key}"]`);
  const detailEl = document.querySelector(`[data-gauge-detail="${key}"]`);
  if (card) card.style.setProperty('--value', percent);
  if (label) label.textContent = `${Number.isFinite(percent) ? percent.toFixed(0) : 0}%`;
  if (detailEl) detailEl.textContent = detail || '';
}

function animateGauges() {
  document.querySelectorAll('.gauge[style]').forEach(el => {
    const match = el.getAttribute('style').match(/--value:\s*([\d.]+)/);
    if (!match) return;
    const target = parseFloat(match[1]);
    const start = performance.now();
    const duration = 1100;
    const ease = t => 1 - Math.pow(1 - t, 3);
    el.style.setProperty('--value', 0);
    function step(now) {
      const t = Math.min((now - start) / duration, 1);
      el.style.setProperty('--value', target * ease(t));
      if (t < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  });
}

function formatLoad(load) {
  if (!load) return 'unknown';
  return `${load.one?.toFixed?.(2) ?? '0.00'} / ${load.five?.toFixed?.(2) ?? '0.00'} / ${load.fifteen?.toFixed?.(2) ?? '0.00'}`;
}

function loadPercent(loadOne, cores) {
  const coreCount = Number.isFinite(cores) && cores > 0 ? cores : 1;
  return Number.isFinite(loadOne) ? (loadOne / coreCount) * 100 : 0;
}

function usedBytes(memory) {
  if (!memory?.totalBytes) return 0;
  return memory.totalBytes - (memory.availableBytes || 0);
}

function clampPercent(value) {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(100, value));
}

function firstUsefulLines(text, limit) {
  return stripANSI(text)
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
    .slice(0, limit)
    .join('\n');
}

function lastLines(text, limit) {
  return stripANSI(text)
    .split('\n')
    .slice(-limit)
    .join('\n')
    .trim();
}

function hexToRgb(hex) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `${r}, ${g}, ${b}`;
}

function applyTheme(name) {
  const hex = THEMES[name] || THEMES[DEFAULT_THEME];
  const rgb = hexToRgb(hex);
  const root = document.documentElement;
  root.style.setProperty('--accent', hex);
  root.style.setProperty('--accent-rgb', rgb);
  root.style.setProperty('--border', `rgba(${rgb}, 0.12)`);
  root.style.setProperty('--accent-bg', `rgba(${rgb}, 0.10)`);
  root.style.setProperty('--panel', `rgba(${rgb}, 0.04)`);
  root.style.setProperty('--panel2', `rgba(${rgb}, 0.07)`);
  localStorage.setItem(THEME_STORAGE_KEY, name);
}

function loadTheme() {
  const saved = localStorage.getItem(THEME_STORAGE_KEY);
  applyTheme(saved && THEMES[saved] ? saved : DEFAULT_THEME);
}

function loadDisplayEffects() {
  try {
    return {
      ...DEFAULT_DISPLAY_EFFECTS,
      ...JSON.parse(localStorage.getItem(DISPLAY_EFFECTS_STORAGE_KEY) || '{}'),
    };
  } catch {
    return { ...DEFAULT_DISPLAY_EFFECTS };
  }
}

function applyDisplayEffects(effects = loadDisplayEffects()) {
  const next = { ...DEFAULT_DISPLAY_EFFECTS, ...effects };
  document.body.classList.toggle('effect-flicker', next.flicker);
  document.body.classList.toggle('effect-sync-drift', next.syncDrift);
  localStorage.setItem(DISPLAY_EFFECTS_STORAGE_KEY, JSON.stringify(next));
}

function customTitleValue() {
  return localStorage.getItem(CCC_CUSTOM_TITLE_STORAGE_KEY) || 'Container Code Companion';
}

function applyCustomTitle() {
  const display = document.getElementById('custom-title-display');
  if (display) display.textContent = customTitleValue();
}

function bindCustomTitleEditor() {
  const input = document.getElementById('custom-title-input');
  if (!input) return;
  input.addEventListener('input', () => {
    localStorage.setItem(CCC_CUSTOM_TITLE_STORAGE_KEY, input.value.trim());
    applyCustomTitle();
  });
  document.getElementById('custom-title-reset')?.addEventListener('click', () => {
    localStorage.removeItem(CCC_CUSTOM_TITLE_STORAGE_KEY);
    input.value = '';
    applyCustomTitle();
  });
}

function stripANSI(value) {
  return String(value || '').replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
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

function directoryName(path) {
  const parts = String(path || '/').split('/').filter(Boolean);
  parts.pop();
  return `/${parts.join('/')}`;
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

loadTheme();
applyDisplayEffects();
applyCustomTitle();
loadHealth();
refresh();
document.getElementById('login-panel').addEventListener('submit', login);
document.getElementById('logout-button').addEventListener('click', logout);
document.getElementById('refresh-button').addEventListener('click', refresh);
document.getElementById('top-preferences-button').addEventListener('click', () => selectSection('settings'));
document.querySelectorAll('.sidebar button').forEach(button => {
  button.addEventListener('click', () => selectSection(button.dataset.section));
});
