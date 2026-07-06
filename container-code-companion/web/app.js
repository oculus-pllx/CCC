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
  chronicle: 'Claude Chronicle',
  github: 'GitHub',
  'ssh-keys': 'SSH Key Inventory',
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
let lastCCCUpdateStatusCheck = 0;
let cccUpdateStatusInFlight = false;
let cccUpdateStatusMessage = 'Not checked in this browser session.';
let networkPollTimer = null;
let lastNetworkSample = null;
let networkHistory = [];
let terminalInitialized = false;
let batchUploadInProgress = false;

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
  updateTopbarUpdateAlert();
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
  updateTopbarUpdateAlert();
  if (currentSection === 'updates' || currentSection === 'overview') {
    if (currentSection === 'overview') {
      updateOverviewLive();
      maybeRefreshCCCUpdateStatus();
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
  if (!signedIn) closeMobileNav();
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
  document.body.classList.toggle('terminal-effects-suppressed', section === 'terminal');
  document.getElementById('section-title').textContent = titles[section] || section;
  document.querySelectorAll('.sidebar button').forEach(button => {
    button.classList.toggle('active', button.dataset.section === section);
  });
  closeMobileNav();
  renderSection(section);
  if (section === 'updates') {
    refreshCCCUpdateStatus();
  } else if (section === 'overview') {
    maybeRefreshCCCUpdateStatus(true);
  }
}

function openMobileNav() {
  document.body.classList.add('mobile-nav-open');
  document.getElementById('mobile-nav-overlay').hidden = false;
  document.getElementById('mobile-menu-button').setAttribute('aria-expanded', 'true');
}

function closeMobileNav() {
  document.body.classList.remove('mobile-nav-open');
  const overlay = document.getElementById('mobile-nav-overlay');
  if (overlay) overlay.hidden = true;
  const button = document.getElementById('mobile-menu-button');
  if (button) button.setAttribute('aria-expanded', 'false');
}

function toggleMobileNav() {
  if (document.body.classList.contains('mobile-nav-open')) closeMobileNav();
  else openMobileNav();
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
    chronicle: renderChronicle,
    github: renderGitHub,
    'ssh-keys': renderSSHKeyInventoryPage,
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
  const sshSessions = snapshot.sshSessions || { total: 0, uniqueUsers: 0, users: [] };
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
        ${statusTile('SSH', `${sshSessions.total || 0} sessions`)}
      </section>

      <section class="gauge-grid">
        ${gauge('CPU Load', cpuPercent, `${formatLoad(data.load)} · ${data.cpu?.cores || 1} cores`, 'cpu')}
        ${gauge('Memory', data.memory?.usedPercent, `${formatBytes(usedBytes(data.memory))} / ${formatBytes(data.memory?.totalBytes || 0)}`, 'memory')}
        ${gauge('Disk', data.disk?.usedPercent, `${formatBytes(data.disk?.usedBytes || 0)} / ${formatBytes(data.disk?.totalBytes || 0)} on ${data.disk?.mount || '/'}`, 'disk')}
      </section>

      <section class="dashboard-grid">
        <div class="dash-panel">
          <h3>Update Status</h3>
          <button id="overview-update-badge" class="badge badge-link ${updateBadgeClass(updateBadge)}" data-nav-updates>${escapeHTML(updateBadge)}</button>
          <p id="overview-update-check-state" class="muted update-check-state">${escapeHTML(cccUpdateStatusMessage)}</p>
          <pre id="overview-update-output" class="mini-output">${escapeHTML(firstUsefulLines(updatePanelText(updateText, updateLog), 8))}</pre>
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
    <p class="section-description">This page reflects the network state visible from inside the LXC container. Persistent network changes such as IP address, bridge, gateway, VLAN, and DNS settings should be managed from the Proxmox host so the container configuration and running system stay aligned.</p>
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

function renderClaudeSettings(account) {
  const cs = account.claudeSettings || {};
  const username = account.username;

  function boolToggle(key, label) {
    const val = cs[key];
    const enabled = val === true;
    const cls = enabled ? 'plugin-toggle enabled' : 'plugin-toggle disabled';
    const text = (enabled ? '● ' : '○ ') + label;
    return `<button class="${cls}" data-claude-toggle="${escapeAttribute(username)}" data-claude-key="${escapeAttribute(key)}" data-claude-val="${enabled}">${text}</button>`;
  }

  const windowVal = typeof cs.autoCompactWindow === 'number' ? cs.autoCompactWindow : '';
  const windowInput = `<label class="muted" style="font-size:0.82em;display:flex;align-items:center;gap:4px">compact&nbsp;at<input type="number" class="claude-window-input" data-claude-number="${escapeAttribute(username)}" value="${escapeAttribute(String(windowVal))}" min="100000" max="1000000" step="10000" placeholder="default" style="width:90px;margin:0 2px">&nbsp;tokens</label>`;

  return `
    <div class="user-plugin-row" style="margin-top:4px">
      <span class="muted" style="font-size:0.82em;margin-right:6px">Claude:</span>
      ${boolToggle('autoCompactEnabled', 'Auto-compact')}
      ${boolToggle('alwaysThinkingEnabled', 'Always thinking')}
      ${boolToggle('skipDangerousModePermissionPrompt', 'Skip danger prompt')}
      ${windowInput}
      <button class="small-button" data-claude-apply-all="${escapeAttribute(username)}" title="Copy these settings to all accounts">Apply to all</button>
    </div>
  `;
}

function renderTmuxSessions(account) {
  const sessions = account.tmuxSessions || [];
  const username = account.username;

  const sessionRows = sessions.map(s => {
    const dot = s.attachedClients > 0
      ? '<span style="color:#6db86d">●</span>'
      : '<span style="color:#555">○</span>';
    const statusLabel = s.attachedClients > 0
      ? '<span class="badge ok">attached</span>'
      : `<span class="muted">idle ${idleLabel(s.idleSeconds)}</span>`;
    const winLabel = `<span class="muted">${s.windows} ${s.windows === 1 ? 'window' : 'windows'}</span>`;
    const name = escapeHTML(s.name);
    const nameAttr = escapeAttribute(s.name);
    return `
      <div class="tmux-session-row">
        <span class="tmux-session-info">${dot} <strong>${name}</strong> ${statusLabel} ${winLabel}</span>
        <span class="tmux-session-actions">
          <button class="small-button" data-tmux-attach="${escapeAttribute(username)}" data-tmux-session="${nameAttr}">Attach</button>
          <button class="small-button" data-tmux-rename="${escapeAttribute(username)}" data-tmux-session="${nameAttr}">Rename</button>
          <button class="small-button" data-tmux-sendkeys="${escapeAttribute(username)}" data-tmux-session="${nameAttr}">Send Keys</button>
          <button class="small-button danger-button" data-tmux-kill="${escapeAttribute(username)}" data-tmux-session="${nameAttr}">Kill</button>
        </span>
      </div>`;
  }).join('');

  const emptyMsg = sessions.length === 0
    ? '<p class="muted" style="font-size:0.85em;margin:4px 0">No tmux sessions</p>'
    : '';

  return `
    <div class="tmux-sessions-block">
      <div class="tmux-sessions-header">
        <span class="label">Tmux Sessions</span>
        <span class="tmux-sessions-footer-actions">
          <button class="small-button" data-tmux-new="${escapeAttribute(username)}">+ New Session</button>
          ${sessions.length > 0 ? `<button class="small-button danger-button" data-tmux-killall="${escapeAttribute(username)}">Kill All</button>` : ''}
        </span>
      </div>
      ${emptyMsg}
      ${sessionRows}
    </div>`;
}

function idleLabel(seconds) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  return `${Math.floor(seconds / 3600)}h`;
}

function renderAccounts() {
  const accounts = snapshot.accounts || [];
  return `
    <div class="account-create">
      <input id="account-username" type="text" placeholder="username">
      <input id="account-password" type="password" placeholder="initial password">
      <input id="account-shell" type="text" value="/bin/bash" placeholder="/bin/bash">
      <button id="create-account-button" class="small-button">Create Account</button>
      <button id="sync-all-agent-configs-button" class="small-button">Sync All Account Configs</button>
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
            <button class="small-button" data-account-setup-profile="${escapeAttribute(account.username)}">Setup CCC Profile</button>
            <button class="small-button" data-account-sync-configs="${escapeAttribute(account.username)}">Sync Account Configs</button>
            <button class="small-button" data-account-password="${escapeAttribute(account.username)}">Password</button>
            <button class="small-button" data-account-shell="${escapeAttribute(account.username)}" data-current-shell="${escapeAttribute(account.shell)}">Shell</button>
            <button class="small-button" data-account-groups="${escapeAttribute(account.username)}" data-current-groups="${escapeAttribute(account.groups)}">Groups</button>
            <button class="small-button danger-button" data-account-delete="${escapeAttribute(account.username)}">Delete</button>
          </div>
          ${renderTmuxSessions(account)}
          ${renderClaudeSettings(account)}
          <p class="section-description">First login checklist: run <code>claude</code>, <code>codex</code>, <code>gemini</code>, and optionally <code>gh auth login</code>.</p>
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
        <details class="file-upload-details" id="file-upload-details">
          <summary class="small-button">Upload &#x25be;</summary>
          <div class="file-upload-dropdown">
            <label for="file-upload-input">Single file</label>
            <input id="file-upload-input" type="file" hidden>
            <label for="file-upload-multi-input">Multiple files</label>
            <input id="file-upload-multi-input" type="file" multiple hidden>
            <label for="file-upload-folder-input">Folder</label>
            <input id="file-upload-folder-input" type="file" webkitdirectory hidden>
          </div>
        </details>
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
          <input type="checkbox" id="file-select-all">
          <span>Type</span>
          <span>Name</span>
          <span>Size</span>
          <span>Modified</span>
          <span></span>
        </div>
        <div id="file-selection-bar">
          <span id="file-selection-count">No items selected</span>
          <button id="file-selection-download" class="small-button" disabled>Download</button>
          <button id="file-selection-clear" class="small-button">Clear</button>
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

function renderAutoUpdatePanel() {
  const enabled = snapshot.updates?.autoUpdateEnabled || false;
  const lastRun = snapshot.updates?.autoUpdateLastRun || '';
  const freq = snapshot.updates?.autoUpdateFreq || 'daily';
  const hour = snapshot.updates?.autoUpdateHour ?? 3;

  const toggleClass = enabled ? 'plugin-toggle enabled' : 'plugin-toggle disabled';
  const toggleLabel = enabled ? 'ON' : 'OFF';

  const freqOptions = [
    ['daily', 'Daily'],
    ['every2days', 'Every 2 days'],
    ['every3days', 'Every 3 days'],
    ['weekly-0', 'Weekly (Sun)'],
    ['weekly-1', 'Weekly (Mon)'],
    ['weekly-2', 'Weekly (Tue)'],
    ['weekly-3', 'Weekly (Wed)'],
    ['weekly-4', 'Weekly (Thu)'],
    ['weekly-5', 'Weekly (Fri)'],
    ['weekly-6', 'Weekly (Sat)'],
  ];

  const freqSelect = `<select id="autoupdate-freq" ${enabled ? '' : 'disabled'}>
    ${freqOptions.map(([val, label]) =>
      `<option value="${val}"${val === freq ? ' selected' : ''}>${escapeHTML(label)}</option>`
    ).join('')}
  </select>`;

  const hourSelect = `<select id="autoupdate-hour" ${enabled ? '' : 'disabled'}>
    ${Array.from({length: 24}, (_, h) => {
      const display = h === 0 ? '12 AM' : h === 12 ? '12 PM' : h < 12 ? `${h} AM` : `${h - 12} PM`;
      return `<option value="${h}"${h === hour ? ' selected' : ''}>${display}</option>`;
    }).join('')}
  </select>`;

  return `
    <div class="autoupdate-panel">
      <div class="autoupdate-row">
        <span class="autoupdate-label">Auto-Update</span>
        <button class="${toggleClass}" id="autoupdate-toggle">${toggleLabel}</button>
        ${enabled ? `<span class="muted" style="font-size:0.8em">Schedule: ${freqSelect} at ${hourSelect}</span>` : ''}
      </div>
      ${lastRun ? `<p class="muted" style="font-size:0.8em;margin:2px 0 0 0">Last run: ${escapeHTML(lastRun)}</p>` : ''}
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
    ${renderAutoUpdatePanel()}
    <p id="update-check-state" class="muted update-check-state">${escapeHTML(cccUpdateStatusMessage)}</p>
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
  const projectRoot = snapshot.projectRoot || {};
  return `
    <div class="project-root-health">
      <h3>Shared Workspace</h3>
      <dl class="facts">
        <dt>Project root</dt><dd>${escapeHTML(projectRoot.root || '/srv/ccc/projects')}</dd>
        <dt>Permission health</dt><dd>${escapeHTML(projectRoot.summary || 'unknown')} ${projectRoot.mode ? `(${escapeHTML(projectRoot.mode)})` : ''}</dd>
      </dl>
      <div class="action-row">
        <button id="shared-workspace-status-button" class="small-button">Check Migration</button>
        <button id="shared-workspace-apply-button" class="small-button">Migrate Existing Projects</button>
        <button id="repair-project-permissions-button" class="small-button">Repair Permissions</button>
      </div>
    </div>
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
    <div class="project-create project-clone">
      <strong>Clone Repository</strong>
      <div class="project-clone-controls">
        <input id="project-clone-remote" type="text" placeholder="git@github.com:owner/repo.git or https://host/owner/repo.git">
        <input id="project-clone-name" type="text" placeholder="optional-project-name">
        <button id="clone-project-button" class="small-button">Clone</button>
      </div>
    </div>
    <div class="project-list">
      ${(snapshot.projects || []).map(project => `
        <div class="project-row-wrap">
          <section class="project-row">
            <div>
              <strong>${escapeHTML(project.name)}</strong>
              <p>${escapeHTML(project.path)}</p>
              <span>${escapeHTML(project.gitBranch || 'not a git repo')}</span>
            </div>
            <div class="action-row">
              <button class="small-button" data-project-browse="${escapeAttribute(project.path)}">Files</button>
              <button class="small-button" data-project-open="${escapeAttribute(project.path)}">VS Code</button>
              ${project.gitRepo ? `<button class="small-button" data-project-pull="${escapeAttribute(project.name)}">Pull Latest</button>` : ''}
              <button class="small-button" data-project-rename="${escapeAttribute(project.name)}">Rename</button>
              <button class="small-button danger-button" data-project-delete="${escapeAttribute(project.name)}">Delete</button>
              <button class="small-button ssh-toggle-btn${project.sshKeyExists ? ' ssh-has-key' : ''}" data-project="${escapeAttribute(project.name)}">SSH &#9662;</button>
            </div>
          </section>
          <div class="project-ssh-panel" id="ssh-panel-${escapeAttribute(project.name)}" hidden>
            <div class="ssh-panel-inner">
              <div class="ssh-status-row">
                Key: <span class="${project.sshKeyExists ? 'key-exists' : 'key-missing'}">&#9679;</span>
                <span class="ssh-fingerprint" id="ssh-fp-${escapeAttribute(project.name)}">${escapeHTML(project.sshKeyExists ? '(loading...)' : 'no key')}</span>
              </div>
              <div class="ssh-host-row">
                Test machine:
                <input class="ssh-host-input" type="text"
                       id="ssh-host-${escapeAttribute(project.name)}"
                       value="${escapeAttribute(project.testHost || '')}"
                       placeholder="IP or hostname">
                <button class="small-button ssh-save-host-btn" data-project="${escapeAttribute(project.name)}">Save</button>
              </div>
              <div class="ssh-actions-row">
                <button class="small-button ssh-generate-btn" data-project="${escapeAttribute(project.name)}">Generate Key</button>
                <button class="small-button ssh-delete-key-btn" data-project="${escapeAttribute(project.name)}"${!project.sshKeyExists ? ' disabled' : ''}>Delete Key</button>
                <button class="small-button ssh-copy-key-btn" data-project="${escapeAttribute(project.name)}"${!project.sshKeyExists ? ' disabled' : ''}>Copy Public Key</button>
              </div>
              <div class="ssh-actions-row">
                <button class="small-button ssh-deploy-btn" data-project="${escapeAttribute(project.name)}"${(!project.sshKeyExists || !project.testHost) ? ' disabled' : ''}>Deploy to Test Machine</button>
                <button class="small-button ssh-connect-btn" data-project="${escapeAttribute(project.name)}"${(!project.sshKeyExists || !project.testHost) ? ' disabled' : ''}>SSH Connect</button>
              </div>
              <div class="ssh-panel-output" id="ssh-output-${escapeAttribute(project.name)}" hidden></div>
            </div>
          </div>
        </div>
      `).join('') || '<p>No projects yet.</p>'}
    </div>
    <pre id="project-output" class="output" hidden></pre>
  `;
}

function renderConfigs() {
  const accounts = snapshot.accounts || [];
  if (!accounts.length) return '<p>No user accounts found.</p>';

  function configBadge(cfg) {
    if (!cfg.exists) return `<span class="user-cfg-file missing" title="${escapeAttribute(cfg.path)}">${escapeHTML(cfg.name)}</span>`;
    return `<span class="user-cfg-file ok" title="${escapeAttribute(cfg.path)}">${escapeHTML(cfg.name)}</span>`;
  }

  function editableConfigs(cfgs) {
    return cfgs.filter(c => c.exists && !c.isDir && (c.name.includes('mcp') || c.name.includes('settings') || c.name.includes('CLAUDE') || c.name.includes('AGENTS') || c.name.includes('GEMINI')));
  }

  function pluginToggleBtn(username, plugin) {
    const cls = plugin.enabled ? 'plugin-toggle enabled' : 'plugin-toggle disabled';
    const label = plugin.enabled ? '● ' + escapeHTML(plugin.shortName) : '○ ' + escapeHTML(plugin.shortName);
    return `<button class="${cls}" data-plugin-toggle="${escapeAttribute(username)}" data-plugin-name="${escapeAttribute(plugin.name)}" data-plugin-enabled="${plugin.enabled}">${label}</button>`;
  }

  const mainUser = accounts[0]?.username || '';

  const blocks = accounts.map(account => {
    const cfgs = account.agentConfigs || [];
    const plugins = account.plugins || [];
    const editable = editableConfigs(cfgs);
    const presentCount = cfgs.filter(c => c.exists).length;
    const isMain = account.username === mainUser;
    return `
      <div class="user-config-block">
        <div class="user-config-header">
          <strong>${escapeHTML(account.username)}</strong>
          ${isMain ? '<span class="badge ok">main</span>' : '<span class="badge">work identity</span>'}
          <span class="muted">${escapeHTML(account.home)} · ${presentCount}/${cfgs.length} configs</span>
          <div class="action-row" style="margin-left:auto">
            <button class="small-button" data-account-sync-configs="${escapeAttribute(account.username)}">Sync Configs</button>
          </div>
        </div>
        <div class="user-cfg-file-grid">
          ${cfgs.map(configBadge).join('')}
        </div>
        ${plugins.length ? `
        <div class="user-plugin-row">
          <span class="muted" style="font-size:0.82em;margin-right:6px">Plugins:</span>
          ${plugins.map(p => pluginToggleBtn(account.username, p)).join('')}
          <span class="muted" style="font-size:0.75em;margin-left:4px" title="If Claude Code shows a marketplace warning for a plugin on startup, click Sync Configs or toggle any plugin to refresh the cache.">⚠ startup warning? click a toggle or Sync Configs</span>
        </div>` : ''}
        ${editable.length ? `
        <div class="action-row" style="margin-top:8px;flex-wrap:wrap">
          ${editable.map(c => `<button class="small-button" data-config-edit="${escapeAttribute(c.path)}">${escapeHTML(c.name)}</button>`).join('')}
        </div>` : ''}
      </div>
    `;
  }).join('');

  return `
    <div class="user-config-list">
      ${blocks}
    </div>
    <pre id="config-output" class="output" hidden></pre>
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

function renderChronicle() {
  return `
    <p class="section-description">Harvest Fable-5 transcript patterns into config-delta proposals, review them, and publish a selection to oculus-configs.</p>
    <div class="action-row">
      <button id="chronicle-run-btn" class="small-button">Run Chronicle</button>
      <span id="chronicle-run-state" class="muted"></span>
    </div>
    <pre id="chronicle-run-log" class="output" hidden></pre>
    <div id="chronicle-pending"><p class="muted">Loading pending items…</p></div>
    <pre id="chronicle-publish-output" class="output" hidden></pre>
  `;
}

function bindChronicle() {
  const runBtn = document.getElementById('chronicle-run-btn');
  if (runBtn) runBtn.addEventListener('click', runChronicle);
  loadChroniclePending();
}

async function loadChroniclePending() {
  const container = document.getElementById('chronicle-pending');
  if (!container) return;
  try {
    const resp = await fetch('/api/chronicle-pending', { credentials: 'include' });
    if (!resp.ok) {
      let message = 'HTTP ' + resp.status;
      try { message = (await resp.json()).error || message; } catch {}
      throw new Error(message);
    }
    const pending = await resp.json();
    renderChroniclePendingList(pending);
  } catch (err) {
    container.innerHTML = `<p class="error-text">${escapeHTML(err.message)}</p>`;
  }
}

function renderChroniclePendingList(pending) {
  const container = document.getElementById('chronicle-pending');
  if (!container) return;
  const items = (pending && pending.items) || [];
  if (!pending || !pending.available || items.length === 0) {
    container.innerHTML = '<p class="muted">No pending items — run Chronicle to synthesize.</p>';
    return;
  }
  const rows = items.map((item, i) => `
    <label class="chronicle-item">
      <input type="checkbox" class="chronicle-item-check" value="${i + 1}" checked>
      <span class="chronicle-item-rule">${escapeHTML(item.rule || '')}</span>
      <span class="chronicle-item-target">${escapeHTML(item.target_file || '')}</span>
    </label>
  `).join('');
  container.innerHTML = `
    <div class="chronicle-pending-header">
      <strong>${items.length} pending item${items.length === 1 ? '' : 's'}</strong>
      <span class="muted">synthesized ${escapeHTML(pending.synthesizedAt || 'unknown')} · ${pending.sessionCount || 0} session${pending.sessionCount === 1 ? '' : 's'}</span>
    </div>
    <div class="chronicle-item-list">${rows}</div>
    <div class="action-row">
      <button id="chronicle-publish-selected" class="small-button">Publish Selected</button>
      <button id="chronicle-publish-all" class="small-button">Publish All</button>
      <button id="chronicle-discard" class="small-button danger-button">Discard</button>
    </div>
  `;
  bindChroniclePublishButtons();
}

function bindChroniclePublishButtons() {
  const sel = document.getElementById('chronicle-publish-selected');
  const all = document.getElementById('chronicle-publish-all');
  const dis = document.getElementById('chronicle-discard');
  if (sel) sel.addEventListener('click', () => {
    const items = Array.from(document.querySelectorAll('.chronicle-item-check:checked'))
      .map((c) => parseInt(c.value, 10));
    if (items.length === 0) {
      showChroniclePublishOutput('Select at least one item, or use Publish All / Discard.');
      return;
    }
    publishChronicle({ mode: 'items', items });
  });
  if (all) all.addEventListener('click', () => publishChronicle({ mode: 'all' }));
  if (dis) dis.addEventListener('click', () => {
    if (confirm('Discard all pending items without publishing?')) {
      publishChronicle({ mode: 'discard' });
    }
  });
}

function showChroniclePublishOutput(text) {
  const out = document.getElementById('chronicle-publish-output');
  if (out) {
    out.hidden = false;
    out.textContent = stripANSI(text);
  }
}

async function publishChronicle(op) {
  showChroniclePublishOutput('Publishing…');
  try {
    const result = await postJSON('/api/chronicle-publish', op);
    showChroniclePublishOutput(result.output || ('Exit code ' + result.exitCode));
    await loadChroniclePending();
    await loadSnapshot(); // refresh oculus-configs data so the new proposal commit shows
  } catch (err) {
    showChroniclePublishOutput(err.message);
  }
}

async function runChronicle() {
  const runBtn = document.getElementById('chronicle-run-btn');
  const state = document.getElementById('chronicle-run-state');
  const log = document.getElementById('chronicle-run-log');
  if (!log) return;
  log.hidden = false;
  log.textContent = 'Starting run…\n';
  if (runBtn) runBtn.disabled = true;
  if (state) state.textContent = 'running…';
  // Pause the snapshot poll so it doesn't re-render the section mid-run.
  stopSnapshotPolling();

  let start;
  try {
    start = await postJSON('/api/chronicle-run', {});
  } catch (err) {
    log.textContent = 'Failed to start run: ' + err.message;
    finishChronicleRun(runBtn, state, false);
    return;
  }
  if (start.exitCode !== 0) {
    log.textContent = stripANSI(start.output || 'Failed to start run.');
    finishChronicleRun(runBtn, state, false);
    return;
  }

  let notRunningCount = 0;
  const poll = setInterval(async () => {
    try {
      const resp = await fetch('/api/chronicle-run-log', { credentials: 'include' });
      if (!resp.ok) throw new Error('HTTP ' + resp.status);
      const data = await resp.json();
      if (log.isConnected) log.textContent = stripANSI(data.log || '(no output yet)\n');
      if (data.running) {
        notRunningCount = 0;
        return;
      }
      // Two consecutive not-running polls == run finished (matches self-update).
      notRunningCount += 1;
      if (notRunningCount >= 2) {
        clearInterval(poll);
        finishChronicleRun(runBtn, state, true);
        loadChroniclePending();
      }
    } catch (err) {
      clearInterval(poll);
      if (log.isConnected) log.textContent += '\n[poll error: ' + err.message + ']';
      finishChronicleRun(runBtn, state, false);
    }
  }, 2000);
}

function finishChronicleRun(runBtn, state, ok) {
  if (runBtn) runBtn.disabled = false;
  if (state) state.textContent = ok ? 'done' : '';
  startSnapshotPolling();
}

function renderGitHub() {
  return `
    <p class="section-description">Manage the shared machine SSH key for GitHub repository access from CCC work identities.</p>
    <div class="info-steps">
      <strong>Multi-user GitHub setup</strong>
      <ol>
        <li>Click <em>Copy Machine Public Key</em> and add it to <a href="https://github.com/settings/keys" target="_blank" rel="noopener">github.com/settings/keys</a> as an SSH key.</li>
        <li>Click <em>Test GitHub Connection</em> to confirm the key is accepted.</li>
        <li>Click <strong>Configure For All Work Identities</strong> — this writes the machine key into every work identity's <code>~/.ssh/config</code> so all users (prime, etc.) can push and pull without individual keys.</li>
        <li>Re-run <em>Configure For All Work Identities</em> any time a new work identity is added.</li>
      </ol>
    </div>
    <div id="github-key-panel">
      <p class="muted">Loading SSH key status...</p>
    </div>
    <div class="action-row github-action-row">
      <button class="small-button" id="github-copy-btn" disabled>Copy Machine Public Key</button>
      <button class="small-button" id="github-test-btn">Test GitHub Connection</button>
      <button class="small-button" id="github-generate-btn">Generate New SSH Key</button>
      <button class="small-button" id="github-configure-btn">Configure For All Work Identities</button>
      <button class="small-button" id="github-promote-btn" hidden>Promote Current User Key</button>
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
      <p class="section-description">For Proxmox LXC containers, CIFS mounts require the container to be allowed to mount filesystems from the Proxmox side. If the mount fails with permission denied, adjust the container configuration on the host or mount the share on Proxmox and bind-mount it into the container.</p>
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
    bindProjectSSHPanels();
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
  if (section === 'ssh-keys') {
    bindSSHKeyInventoryPage();
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
  if (section === 'chronicle') {
    bindChronicle();
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

async function runActionForSnapshot(action) {
  const result = await postJSON('/api/action', { action });
  await loadSnapshot();
  return result;
}

async function refreshCCCUpdateStatus() {
  if (cccUpdateStatusInFlight) return;
  cccUpdateStatusInFlight = true;
  lastCCCUpdateStatusCheck = Date.now();
  cccUpdateStatusMessage = 'Checking GitHub with ccc-update-status...';
  updateCCCUpdateStatusMessage();
  const output = document.getElementById('update-status-output');
  if (output) {
    output.textContent = 'Checking Container Code Companion update status...';
  }
  try {
    const result = await runActionForSnapshot('update-status');
    const checkedAt = new Date();
    const cleanOutput = stripANSI(result.output || '');
    if (cleanOutput && snapshot.updates) {
      snapshot.updates.containerCodeCompanion = cleanOutput;
    }
    cccUpdateStatusMessage = `Last checked ${checkedAt.toLocaleTimeString()}. ${summarizeCCCUpdateStatus(cleanOutput)}`;
    updateTopbarUpdateAlert(cleanOutput);
    if (currentSection === 'updates') {
      renderSection('updates');
    } else if (currentSection === 'overview') {
      updateOverviewUpdateStatusPanel(cleanOutput);
    }
    updateCCCUpdateStatusMessage();
  } catch (error) {
    cccUpdateStatusMessage = `Last check failed ${new Date().toLocaleTimeString()}. ${stripANSI(error.message)}`;
    const errorOutput = document.getElementById('update-status-output');
    if (errorOutput) {
      errorOutput.textContent = stripANSI(error.message);
    }
    updateCCCUpdateStatusMessage();
  } finally {
    cccUpdateStatusInFlight = false;
  }
}

function summarizeCCCUpdateStatus(output) {
  const text = stripANSI(output || '');
  if (text.includes('Up to date')) return 'Up to date.';
  if (text.includes('Update available')) return 'Update available.';
  if (text.includes('No version recorded') || text.includes('Installed: not recorded')) return 'Version not recorded.';
  if (text.includes('Could not reach GitHub')) return 'Could not reach GitHub.';
  if (text.trim()) return 'Check completed.';
  return 'No output returned.';
}

function updateOverviewUpdateStatusPanel(statusText) {
  const updateLog = stripANSI(snapshot.updates?.selfUpdateLog || '');
  const badgeLabel = updateStatusBadge(statusText, updateLog);
  const badge = document.getElementById('overview-update-badge');
  if (badge) {
    badge.textContent = badgeLabel;
    badge.className = `badge badge-link ${updateBadgeClass(badgeLabel)}`.trim();
    badge.setAttribute('data-nav-updates', '');
  }
  const output = document.getElementById('overview-update-output');
  if (output) {
    output.textContent = firstUsefulLines(updatePanelText(statusText, updateLog), 8);
  }
}

function updateTopbarUpdateAlert(statusText = '') {
  const alert = document.getElementById('top-update-alert');
  if (!alert) return;
  const updates = snapshot?.updates || {};
  const text = stripANSI(statusText || updates.containerCodeCompanion || '');
  const logText = stripANSI(updates.selfUpdateLog || '');
  const badgeLabel = updateStatusBadge(text, logText);
  const summary = summarizeCCCUpdateStatus(text);
  alert.hidden = false;
  alert.textContent = `CCC Updates: ${summary}`;
  alert.className = `top-update-alert ${updateBadgeClass(badgeLabel)}`.trim();
}

function updateCCCUpdateStatusMessage() {
  document.querySelectorAll('.update-check-state').forEach(el => {
    el.textContent = cccUpdateStatusMessage;
  });
}

function maybeRefreshCCCUpdateStatus(force = false) {
  const intervalMs = 5 * 60 * 1000;
  if (!force && Date.now() - lastCCCUpdateStatusCheck < intervalMs) return;
  refreshCCCUpdateStatus();
}

// Launches ccc-self-update as a detached background job, then polls
// /api/self-update-log every 2 seconds to show live progress.
// This approach survives the systemd service restart that occurs at step 4
// of the update: the background process writes to /var/log/ccc-self-update.log
// outside the service cgroup, and the new service instance serves the same
// log file when the client reconnects after restart.
async function runSelfUpdateStream() {
  const output = document.getElementById('self-update-output');
  output.hidden = false;
  output.textContent = 'Starting update...\n';
  // Stop the snapshot poll so it doesn't re-render the section and detach
  // this output element from the DOM mid-update.
  stopSnapshotPolling();

  // Trigger the background job. Returns immediately once the detached process
  // is launched — exitCode 0 means the job started, not that it finished.
  let startResult;
  try {
    startResult = await postJSON('/api/self-update', {});
  } catch (err) {
    output.textContent = 'Failed to start update: ' + err.message;
    startSnapshotPolling();
    return;
  }
  if (startResult.exitCode !== 0) {
    output.textContent = startResult.output || 'Failed to start update.';
    startSnapshotPolling();
    return;
  }

  // Poll the log file every 2 seconds. The log persists through service
  // restarts, so the client can reconnect and resume showing progress.
  let notRunningCount = 0;
  let reconnecting = false;

  const logPoll = setInterval(async () => {
    try {
      const resp = await fetch('/api/self-update-log', { credentials: 'include' });
      if (!resp.ok) throw new Error('HTTP ' + resp.status);
      const data = await resp.json();

      reconnecting = false;
      if (output.isConnected) {
        output.textContent = data.log || '(no output yet)\n';
      }

      if (!data.running) {
        notRunningCount++;
        // Wait two quiet polls (4 s) to ensure the log is fully flushed
        // before declaring done. Then hand off to monitorReconnect so it can
        // wait for the service restart that ccc-self-update triggers.
        if (notRunningCount >= 2) {
          clearInterval(logPoll);
          monitorReconnect(output);
        }
      } else {
        notRunningCount = 0;
      }
    } catch {
      // Fetch failed — service is restarting. Show a message once and retry.
      if (!reconnecting) {
        reconnecting = true;
        if (output.isConnected) {
          output.textContent += '\nService restarting — will reconnect...\n';
        }
      }
    }
  }, 2000);
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

async function setAutoUpdateSchedule() {
  const freq = document.getElementById('autoupdate-freq')?.value || 'daily';
  const hour = parseInt(document.getElementById('autoupdate-hour')?.value || '3', 10);
  const action = `set-autoupdate-schedule:${freq}:${hour}`;
  const result = await postJSON('/api/action', { action });
  if (result.exitCode !== 0) {
    const out = document.getElementById('action-output');
    if (out) { out.hidden = false; out.textContent = result.output || 'Schedule change failed.'; }
  }
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
      if (activeUpdateTab === 'app') {
        refreshCCCUpdateStatus();
      }
    });
  });
  document.getElementById('self-update-btn')?.addEventListener('click', runSelfUpdateStream);

  document.getElementById('autoupdate-toggle')?.addEventListener('click', async () => {
    const enabled = snapshot.updates?.autoUpdateEnabled || false;
    const action = enabled ? 'disable-autoupdate' : 'enable-autoupdate';
    const result = await postJSON('/api/action', { action });
    if (result.exitCode !== 0) {
      const out = document.getElementById('action-output');
      if (out) { out.hidden = false; out.textContent = result.output || 'Toggle failed.'; }
      return;
    }
    await loadSnapshot();
    renderSection('updates');
    bindUpdates();
  });

  document.getElementById('autoupdate-freq')?.addEventListener('change', setAutoUpdateSchedule);
  document.getElementById('autoupdate-hour')?.addEventListener('change', setAutoUpdateSchedule);

  document.getElementById('os-update-btn')?.addEventListener('click', () => runAction('os-update'));
}

function bindAccounts() {
  document.getElementById('create-account-button').addEventListener('click', createAccount);
  document.getElementById('sync-all-agent-configs-button')?.addEventListener('click', syncAllAgentConfigs);
  document.querySelectorAll('[data-account-setup-profile]').forEach(button => {
    button.addEventListener('click', () => setupCCCProfile(button.dataset.accountSetupProfile));
  });
  document.querySelectorAll('[data-account-sync-configs]').forEach(button => {
    button.addEventListener('click', () => syncAccountAgentConfigs(button.dataset.accountSyncConfigs));
  });
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

  // tmux attach — switch to terminal and inject attach command
  document.querySelectorAll('[data-tmux-attach]').forEach(button => {
    button.addEventListener('click', () => {
      const session = button.dataset.tmuxSession;
      selectSection('terminal');
      setTimeout(() => sendTerminalInput(`tmux attach-session -t ${session}\n`), 300);
    });
  });

  // tmux new session
  document.querySelectorAll('[data-tmux-new]').forEach(button => {
    button.addEventListener('click', async () => {
      const username = button.dataset.tmuxNew;
      const name = prompt('Session name', 'work');
      if (!name) return;
      await runAccountOperation({ operation: 'tmux-new', username, sessionName: name });
    });
  });

  // tmux kill session
  document.querySelectorAll('[data-tmux-kill]').forEach(button => {
    button.addEventListener('click', async () => {
      const username = button.dataset.tmuxKill;
      const session = button.dataset.tmuxSession;
      if (!confirm(`Kill session "${session}" for ${username}?`)) return;
      await runAccountOperation({ operation: 'tmux-kill', username, sessionName: session });
    });
  });

  // tmux kill all sessions
  document.querySelectorAll('[data-tmux-killall]').forEach(button => {
    button.addEventListener('click', async () => {
      const username = button.dataset.tmuxKillall;
      if (!confirm(`Kill ALL tmux sessions for ${username}?`)) return;
      await runAccountOperation({ operation: 'tmux-kill-all', username });
    });
  });

  // tmux rename
  document.querySelectorAll('[data-tmux-rename]').forEach(button => {
    button.addEventListener('click', async () => {
      const username = button.dataset.tmuxRename;
      const session = button.dataset.tmuxSession;
      const newName = prompt(`Rename session "${session}" to:`, session);
      if (!newName || newName === session) return;
      await runAccountOperation({ operation: 'tmux-rename', username, sessionName: session, newName });
    });
  });

  // tmux send keys
  document.querySelectorAll('[data-tmux-sendkeys]').forEach(button => {
    button.addEventListener('click', async () => {
      const username = button.dataset.tmuxSendkeys;
      const session = button.dataset.tmuxSession;
      const keys = prompt(`Send command to "${session}" (${username}):`);
      if (!keys) return;
      await runAccountOperation({ operation: 'tmux-send-keys', username, sessionName: session, keys });
    });
  });

  // Claude settings bool toggles
  document.querySelectorAll('[data-claude-toggle]').forEach(button => {
    button.addEventListener('click', () => {
      const username = button.dataset.claudeToggle;
      const key = button.dataset.claudeKey;
      const current = button.dataset.claudeVal === 'true';
      setClaudeSetting(username, key, !current);
    });
  });

  // Claude settings autoCompactWindow number input
  document.querySelectorAll('.claude-window-input').forEach(input => {
    input.addEventListener('change', () => {
      const username = input.dataset.claudeNumber;
      const val = parseInt(input.value, 10);
      if (!isNaN(val) && val >= 100000 && val <= 1000000) {
        setClaudeSetting(username, 'autoCompactWindow', val);
      }
    });
  });

  // Apply to all accounts
  document.querySelectorAll('[data-claude-apply-all]').forEach(button => {
    button.addEventListener('click', () => applyClaudeSettingsToAll(button.dataset.claudeApplyAll));
  });
}

async function setupCCCProfile(username) {
  await runAccountOperation({ operation: 'setup-ccc-profile', username });
}

async function syncAccountAgentConfigs(username) {
  await runAccountOperation({ operation: 'sync-agent-configs', username });
}

async function syncAllAgentConfigs() {
  showAccountOutput('Running...');
  try {
    const result = await postJSON('/api/action', { action: 'sync-all-agent-configs' });
    await loadSnapshot();
    renderSection('accounts');
    showAccountOutput(result.output || 'agent configs synced for all users');
  } catch (error) {
    showAccountOutput(error.message);
  }
}

async function createAccount() {
  const username = document.getElementById('account-username').value.trim();
  if (!username) {
    showAccountOutput('Error: username is required');
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

async function setClaudeSetting(username, key, value) {
  showAccountOutput('Updating...');
  try {
    const result = await postJSON('/api/claude-settings', { username, settings: { [key]: value } });
    await loadSnapshot();
    renderSection('accounts');
    showAccountOutput(result.output || 'Setting updated');
  } catch (error) {
    showAccountOutput(error.message);
  }
}

async function applyClaudeSettingsToAll(sourceUsername) {
  if (!confirm(`Apply ${sourceUsername}'s Claude settings to all accounts?`)) return;
  showAccountOutput('Applying to all accounts...');
  const sourceAccount = (snapshot.accounts || []).find(a => a.username === sourceUsername);
  const cs = sourceAccount?.claudeSettings || {};
  const settings = {};
  for (const key of ['autoCompactEnabled', 'autoCompactWindow', 'alwaysThinkingEnabled', 'skipDangerousModePermissionPrompt']) {
    if (key in cs) settings[key] = cs[key];
  }
  try {
    const result = await postJSON('/api/claude-settings', { username: sourceUsername, settings, allAccounts: true });
    await loadSnapshot();
    renderSection('accounts');
    showAccountOutput(result.output || 'Applied to all accounts');
  } catch (error) {
    showAccountOutput(error.message);
  }
}

async function runAccountOperation(payload) {
  showAccountOutput('Running...');
  try {
    const result = await postJSON('/api/account', payload);
    const text = result.output || 'account updated';
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
    showAccountOutput(text);
  } catch (error) {
    showAccountOutput(error.message);
  }
}

function showAccountOutput(text) {
  const output = document.getElementById('account-output');
  if (!output) return;
  output.hidden = false;
  output.textContent = stripANSI(text);
}

function bindGitHub() {
  loadGitHubStatus();
  document.getElementById('github-copy-btn').addEventListener('click', copyGitHubPublicKey);
  document.getElementById('github-generate-btn').addEventListener('click', generateGitHubKey);
  document.getElementById('github-test-btn').addEventListener('click', testGitHubConnection);
  document.getElementById('github-configure-btn').addEventListener('click', configureGitHubForAllUsers);
  document.getElementById('github-promote-btn').addEventListener('click', promoteCurrentUserGitHubKey);
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
          <dt>Configured users</dt><dd>${escapeHTML((status.configuredUsers || []).join(', ') || 'none yet')}</dd>
        </dl>
        <p class="section-description">Copy the public key above, then <a href="https://github.com/settings/ssh/new" target="_blank" rel="noopener">add it to GitHub</a>.</p>
      `;
      const copyButton = document.getElementById('github-copy-btn');
      if (copyButton) {
        copyButton.disabled = false;
        copyButton.dataset.publicKey = status.publicKey;
      }
    } else {
      panel.innerHTML = `<p class="muted">No SSH key found at <code>${escapeHTML(status.keyPath)}</code>. Generate one below.</p>`;
      const copyButton = document.getElementById('github-copy-btn');
      if (copyButton) {
        copyButton.disabled = true;
        delete copyButton.dataset.publicKey;
      }
    }
    const promoteButton = document.getElementById('github-promote-btn');
    if (promoteButton) {
      promoteButton.hidden = Boolean(status.keyExists) || !status.currentUserKeyExists;
    }
  } catch (err) {
    panel.innerHTML = `<p class="error-text">Failed to load SSH key status: ${escapeHTML(err.message)}</p>`;
    const copyButton = document.getElementById('github-copy-btn');
    if (copyButton) {
      copyButton.disabled = true;
      delete copyButton.dataset.publicKey;
    }
    const promoteButton = document.getElementById('github-promote-btn');
    if (promoteButton) promoteButton.hidden = true;
  }
}

async function copyGitHubPublicKey() {
  const button = document.getElementById('github-copy-btn');
  const publicKey = button?.dataset.publicKey || '';
  if (!button || !publicKey) return;
  const copied = await copyTextToClipboard(publicKey);
  showCopyButtonState(button, copied ? 'Copied!' : 'Copy Failed');
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
  setTimeout(() => { button.textContent = 'Copy Machine Public Key'; }, 2000);
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

async function configureGitHubForAllUsers() {
  const output = document.getElementById('github-output');
  output.hidden = false;
  output.textContent = 'Configuring work identities for the machine GitHub key...';
  try {
    const usernames = (snapshot?.accounts || []).map(account => account.username).filter(Boolean);
    const result = await postJSON('/api/github', { action: 'configure-users', usernames });
    output.textContent = result.output || 'Configured.';
    loadGitHubStatus();
  } catch (err) {
    output.textContent = `Error: ${err.message}`;
  }
}

async function promoteCurrentUserGitHubKey() {
  const output = document.getElementById('github-output');
  output.hidden = false;
  output.textContent = 'Promoting current user key to managed machine key...';
  try {
    const result = await postJSON('/api/github', { action: 'promote-current-user-key' });
    output.textContent = result.exitCode === 0
      ? `Machine key promoted.\n\nPublic key:\n${result.output}`
      : `Failed:\n${result.output}`;
    loadGitHubStatus();
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
  document.getElementById('file-upload-input')?.addEventListener('change', (e) => {
    document.getElementById('file-upload-details')?.removeAttribute('open');
    uploadCurrentDirectory(e);
  });
  const multiInput = document.getElementById('file-upload-multi-input');
  if (multiInput) multiInput.addEventListener('change', () => {
    document.getElementById('file-upload-details')?.removeAttribute('open');
    uploadBatch(multiInput);
  });
  const folderInput = document.getElementById('file-upload-folder-input');
  if (folderInput) folderInput.addEventListener('change', () => {
    document.getElementById('file-upload-details')?.removeAttribute('open');
    uploadBatch(folderInput);
  });
  const dlSelected = document.getElementById('file-selection-download');
  if (dlSelected) dlSelected.addEventListener('click', () => {
    const paths = [...document.querySelectorAll('.file-select-checkbox:checked')]
      .map(cb => cb.dataset.path);
    if (paths.length > 0) downloadZip(paths);
  });
  const clearBtn = document.getElementById('file-selection-clear');
  if (clearBtn) clearBtn.addEventListener('click', () => {
    document.querySelectorAll('.file-select-checkbox').forEach(cb => cb.checked = false);
    updateSelectionBar();
  });
  document.getElementById('file-select-all')?.addEventListener('change', (e) => {
    document.querySelectorAll('.file-select-checkbox').forEach(cb => {
      cb.checked = e.target.checked;
    });
    updateSelectionBar();
  });
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
    list.querySelectorAll('.file-row').forEach(row => {
      row.addEventListener('click', (e) => {
        if (e.target.closest('.file-select-checkbox, .file-row-download')) return;
        if (row.dataset.type === 'dir') {
          filePath = row.dataset.path;
          loadFiles(filePath);
        } else {
          selectFileEntry(row);
        }
      });
    });
    list.querySelectorAll('.file-select-checkbox').forEach(cb => {
      cb.addEventListener('change', updateSelectionBar);
    });
    list.querySelectorAll('.file-row-download').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (btn.dataset.type === 'dir') {
          downloadZip([btn.dataset.path]);
        } else {
          window.location.href = `/api/file-download?path=${encodeURIComponent(btn.dataset.path)}`;
        }
      });
    });
    updateSelectionBar();
  } catch (error) {
    list.textContent = error.message;
    if (count) count.textContent = 'Unavailable';
  }
}

function renderFileEntry(entry) {
  const isDir = entry.type === 'dir';
  return `
    <div class="file-row ${isDir ? 'directory' : 'regular-file'}"
         data-path="${escapeAttribute(entry.path)}"
         data-type="${escapeAttribute(entry.type)}"
         data-name="${escapeAttribute(entry.name)}"
         data-size="${escapeAttribute(formatBytes(entry.size))}"
         data-mtime="${escapeAttribute(entry.mtime || '')}"
         data-mode="${escapeAttribute(entry.mode || '')}">
      <input type="checkbox" class="file-select-checkbox" data-path="${escapeAttribute(entry.path)}">
      <span class="file-entry-icon">${isDir ? 'DIR' : 'FILE'}</span>
      <strong>${escapeHTML(entry.name)}</strong>
      <small>${isDir ? '&mdash;' : escapeHTML(formatBytes(entry.size))}</small>
      <small>${escapeHTML(entry.mtime || '')}</small>
      <button type="button" class="file-row-download"
              data-path="${escapeAttribute(entry.path)}"
              data-type="${escapeAttribute(entry.type)}"
              title="${isDir ? 'Download as zip' : 'Download'}">&#11015;</button>
    </div>
  `;
}

function selectFileEntry(row) {
  selectedFilePath = row.dataset.path;
  currentFile = selectedFilePath;
  document.querySelectorAll('.file-row').forEach(entry => {
    entry.classList.toggle('selected', entry === row);
  });
  document.getElementById('current-file').value = selectedFilePath;
  updateSelectedFileDetail(row);
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

function downloadZip(paths) {
  const qs = paths.map(p => 'path=' + encodeURIComponent(p)).join('&');
  window.location.href = `/api/file-download-zip?${qs}`;
}

function updateSelectionBar() {
  const checkboxes = document.querySelectorAll('.file-select-checkbox:checked');
  const bar = document.getElementById('file-selection-bar');
  const count = document.getElementById('file-selection-count');
  const dlBtn = document.getElementById('file-selection-download');
  if (!bar || !count) return;
  const n = checkboxes.length;
  count.textContent = n === 0 ? 'No items selected' : `${n} item${n === 1 ? '' : 's'} selected`;
  bar.classList.toggle('active', n > 0);
  if (dlBtn) dlBtn.disabled = n === 0;
  updateSelectAll();
}

function updateSelectAll() {
  const all = document.querySelectorAll('.file-select-checkbox');
  const checked = document.querySelectorAll('.file-select-checkbox:checked');
  const selectAll = document.getElementById('file-select-all');
  if (!selectAll || all.length === 0) return;
  selectAll.indeterminate = checked.length > 0 && checked.length < all.length;
  selectAll.checked = all.length > 0 && checked.length === all.length;
}

async function uploadBatch(input) {
  if (batchUploadInProgress) return;
  batchUploadInProgress = true;
  const files = input.files;
  if (!files || files.length === 0) {
    batchUploadInProgress = false;
    return;
  }
  const formData = new FormData();
  for (const file of files) {
    formData.append('file', file);
    formData.append('relpath', file.webkitRelativePath || file.name);
  }
  const output = document.getElementById('file-output');
  if (output) {
    output.hidden = false;
    output.textContent = `Uploading ${files.length} file(s)...`;
  }
  try {
    const resp = await fetch(`/api/file-upload-batch?path=${encodeURIComponent(filePath)}`, {
      method: 'POST',
      body: formData,
      credentials: 'include',
    });
    const data = await resp.json();
    if (!resp.ok) throw new Error(data.error || 'Upload failed');
    if (output) output.textContent = `Uploaded ${data.count} file(s)`;
    await loadFiles(filePath);
  } catch (err) {
    if (output) output.textContent = `Error: ${err.message}`;
  } finally {
    batchUploadInProgress = false;
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
  if (!bindTerminal._visibilityBound) {
    bindTerminal._visibilityBound = true;
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState !== 'visible') return;
      const tab = activeTerminalTab();
      if (!tab?.terminal) return;
      requestAnimationFrame(() => {
        resizeTerminal();
        tab.terminal.refresh(0, tab.terminal.rows - 1);
      });
    });
  }
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
      requestAnimationFrame(resizeTerminal);
      setTimeout(resizeTerminal, 120);
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
  const { width: cellWidth, height: cellHeight } = terminalCellSize(tab);
  const cols = Math.max(40, Math.floor((pane.clientWidth - 16) / cellWidth));
  const rows = Math.max(10, Math.floor((pane.clientHeight - 16) / cellHeight));
  if (cols !== tab.terminal.cols || rows !== tab.terminal.rows) {
    tab.terminal.resize(cols, rows);
  }
}

function terminalCellSize(tab) {
  const dimensions = tab.terminal?._core?._renderService?.dimensions?.css?.cell;
  if (dimensions?.width > 0 && dimensions?.height > 0) {
    return { width: dimensions.width, height: dimensions.height };
  }
  const pane = document.getElementById(`terminal-pane-${tab.id}`);
  const xterm = pane?.querySelector('.xterm');
  const style = xterm ? getComputedStyle(xterm) : null;
  const probe = document.createElement('span');
  probe.textContent = 'W';
  probe.style.position = 'absolute';
  probe.style.visibility = 'hidden';
  probe.style.whiteSpace = 'pre';
  probe.style.fontFamily = style?.fontFamily || 'monospace';
  probe.style.fontSize = style?.fontSize || '13px';
  probe.style.lineHeight = style?.lineHeight || 'normal';
  pane?.appendChild(probe);
  const rect = probe.getBoundingClientRect();
  probe.remove();
  return {
    width: rect.width > 0 ? rect.width : 8,
    height: rect.height > 0 ? rect.height : 17,
  };
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
  if (tab?.terminal) {
    tab.terminal.focus();
    requestAnimationFrame(resizeTerminal);
  }
}

function bindConfigs() {
  document.querySelectorAll('[data-config-edit]').forEach(button => {
    button.addEventListener('click', () => showConfigEditor(button.dataset.configEdit));
  });
  document.querySelectorAll('[data-plugin-toggle]').forEach(button => {
    button.addEventListener('click', () => {
      const username = button.dataset.pluginToggle;
      const plugin = button.dataset.pluginName;
      const currentlyEnabled = button.dataset.pluginEnabled === 'true';
      togglePlugin(username, plugin, !currentlyEnabled);
    });
  });
  document.querySelectorAll('[data-account-sync-configs]').forEach(button => {
    button.addEventListener('click', () => syncConfigsForUser(button.dataset.accountSyncConfigs));
  });
  const saveBtn = document.getElementById('config-editor-save');
  const cancelBtn = document.getElementById('config-editor-cancel');
  if (saveBtn) saveBtn.addEventListener('click', saveConfigFile);
  if (cancelBtn) cancelBtn.addEventListener('click', hideConfigEditor);
}

async function togglePlugin(username, plugin, enable) {
  showConfigOutput('Updating...');
  try {
    const result = await postJSON('/api/account', { operation: 'toggle-plugin', username, plugin, enabled: enable });
    await loadSnapshot();
    renderSection('configs');
    showConfigOutput(result.output || 'Plugin updated');
  } catch (error) {
    showConfigOutput(error.message);
  }
}

async function syncConfigsForUser(username) {
  showConfigOutput('Syncing...');
  try {
    const result = await postJSON('/api/account', { operation: 'sync-agent-configs', username });
    await loadSnapshot();
    renderSection('configs');
    showConfigOutput(result.output || 'Synced');
  } catch (error) {
    showConfigOutput(error.message);
  }
}

function showConfigOutput(text) {
  const el = document.getElementById('config-output');
  if (!el) return;
  el.textContent = text;
  el.hidden = false;
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
  document.getElementById('clone-project-button')?.addEventListener('click', cloneProject);
  document.getElementById('repair-project-permissions-button')?.addEventListener('click', repairProjectPermissions);
  document.getElementById('shared-workspace-status-button')?.addEventListener('click', () => runProjectPageAction('shared-workspace-status'));
  document.getElementById('shared-workspace-apply-button')?.addEventListener('click', () => {
    if (confirm('Migrate existing projects into the shared workspace?')) {
      runProjectPageAction('shared-workspace-apply');
    }
  });
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
  document.querySelectorAll('[data-project-pull]').forEach(button => {
    button.addEventListener('click', () => pullProject(button.dataset.projectPull));
  });
  document.querySelectorAll('[data-project-delete]').forEach(button => {
    button.addEventListener('click', () => deleteProject(button.dataset.projectDelete));
  });
}

async function repairProjectPermissions() {
  await runProjectOperation({ operation: 'repair-permissions' });
}

async function runProjectPageAction(action) {
  showProjectOutput('Running...');
  try {
    const result = await postJSON('/api/action', { action });
    const text = stripANSI(result.output || `Exit code ${result.exitCode}`);
    await loadSnapshot();
    renderSection('projects');
    showProjectOutput(text);
  } catch (error) {
    showProjectOutput(stripANSI(error.message));
  }
}

function showProjectOutput(text) {
  const output = document.getElementById('project-output');
  if (!output) return;
  output.hidden = false;
  output.textContent = text;
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

async function cloneProject() {
  const remote = document.getElementById('project-clone-remote').value.trim();
  const name = document.getElementById('project-clone-name').value.trim();
  await runProjectOperation({ operation: 'clone', remote, name });
}

async function pullProject(name) {
  await runProjectOperation({ operation: 'pull', name });
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
  if (statusText.includes('commit(s) behind') || statusText.includes('Update available')) return 'Updates available';
  if (statusText.includes('Up to date')) return 'Current';
  if (statusText.includes('installed commit is not recorded') || statusText.includes('Installed: not recorded')) return 'Not recorded';
  if (logText.includes('Update script exited with errors') || logText.includes('Download failed')) return 'Update failed';
  if (logText.includes('Self-update successful')) return 'Current';
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

function focusHeaderMessageEditor() {
  selectSection('settings');
  requestAnimationFrame(() => document.getElementById('custom-title-input')?.focus());
}

function stripANSI(value) {
  return String(value || '')
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, '')
    .replace(/\[(?:\d{1,2};)*\d{1,2}m/g, '');
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

async function loadSSHKeyInventory() {
  try {
    const resp = await fetch('/api/ssh-key-operation', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'list-keys' }),
    });
    if (!resp.ok) return [];
    return await resp.json();
  } catch {
    return [];
  }
}

function renderSSHKeyInventoryPage() {
  return '<div id="ssh-key-inventory-placeholder"></div>';
}

function bindSSHKeyInventoryPage() {
  loadSSHKeyInventory().then(keys => {
    const placeholder = document.getElementById('ssh-key-inventory-placeholder');
    if (placeholder) {
      placeholder.outerHTML = renderSSHKeyInventory(keys);
      bindSSHKeyInventory();
    }
  });
}

function renderSSHKeyInventory(keys) {
  const rogueKeys = keys.filter(k =>
    !k.path.startsWith('/etc/ccc/project-keys/') &&
    k.path !== '/etc/ccc/ssh/github_ed25519'
  );
  const rogueCount = rogueKeys.length;
  const summary = `${keys.length} key${keys.length !== 1 ? 's' : ''} · ${rogueCount > 0 ? `⚠ ${rogueCount} outside CCC control` : 'all managed'}`;

  const rows = keys.map(k => {
    const isRogue = !k.path.startsWith('/etc/ccc/project-keys/') && k.path !== '/etc/ccc/ssh/github_ed25519';
    return `<tr class="ssh-key-row${isRogue ? ' rogue' : ''}">
      <td class="key-path">${escapeHTML(k.path)}${isRogue ? ' <span class="rogue-badge">⚠ unmanaged</span>' : ''}</td>
      <td>${escapeHTML(k.owner)}</td>
      <td>${escapeHTML(k.keyType || '—')}</td>
      <td>${escapeHTML(k.mtime || '—')}</td>
      <td><button class="small-button delete-key-btn" data-path="${escapeAttribute(k.path)}">Delete</button></td>
    </tr>`;
  }).join('');

  return `<div class="ssh-key-inventory" id="ssh-key-inventory">
    <div class="ssh-inventory-header" id="ssh-inventory-toggle">
      <span class="toggle-arrow">▾</span> SSH Key Inventory
      <span class="ssh-inventory-summary">${summary}</span>
    </div>
    <div class="ssh-inventory-body" id="ssh-inventory-body">
      <table class="ssh-key-table">
        <thead><tr><th>Path</th><th>Owner</th><th>Type</th><th>Modified</th><th></th></tr></thead>
        <tbody>${rows || '<tr><td colspan="5">No SSH keys found.</td></tr>'}</tbody>
      </table>
    </div>
  </div>`;
}

function bindSSHKeyInventory() {
  const toggle = document.getElementById('ssh-inventory-toggle');
  const body = document.getElementById('ssh-inventory-body');
  if (toggle && body) {
    toggle.addEventListener('click', () => {
      const collapsed = body.style.display === 'none';
      body.style.display = collapsed ? '' : 'none';
      toggle.querySelector('.toggle-arrow').textContent = collapsed ? '▾' : '▸';
    });
  }

  document.querySelectorAll('.delete-key-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const path = btn.dataset.path;
      if (!confirm(`Delete SSH key at ${path}?\n\nThis cannot be undone.`)) return;
      const resp = await fetch('/api/ssh-key-operation', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'delete-key', keyPath: path }),
      });
      if (resp.ok) {
        await refreshSSHKeyInventory();
      } else {
        const data = await resp.json().catch(() => ({}));
        alert(`Delete failed: ${data.error || resp.statusText}`);
      }
    });
  });
}

async function refreshSSHKeyInventory() {
  const keys = await loadSSHKeyInventory();
  const container = document.getElementById('ssh-key-inventory');
  if (container) {
    container.outerHTML = renderSSHKeyInventory(keys);
    bindSSHKeyInventory();
  }
}

// ── Per-project SSH panel ─────────────────────────────────────────────────

function bindProjectSSHPanels() {
  document.querySelectorAll('.ssh-toggle-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const name = btn.dataset.project;
      const panel = document.getElementById(`ssh-panel-${name}`);
      if (!panel) return;
      const isOpen = !panel.hidden;
      panel.hidden = isOpen;
      btn.textContent = isOpen ? 'SSH ▾' : 'SSH ▴';
      if (!isOpen) {
        await refreshSSHPanel(name);
      }
    });
  });

  document.querySelectorAll('.ssh-save-host-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const name = btn.dataset.project;
      const hostInput = document.getElementById(`ssh-host-${name}`);
      const host = hostInput ? hostInput.value.trim() : '';
      showSSHOutput(name, 'Saving...');
      const resp = await fetch('/api/ssh-key-operation', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'save-test-host', projectName: name, testHost: host }),
      });
      const data = await resp.json().catch(() => ({}));
      if (resp.ok) {
        showSSHOutput(name, data.deploymentConfigWarning
          ? `Saved. Note: ${data.deploymentConfigWarning}`
          : 'Test host saved.');
        await refreshSSHPanel(name);
      } else {
        showSSHOutput(name, `Error: ${data.error || resp.statusText}`);
      }
    });
  });

  document.querySelectorAll('.ssh-generate-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const name = btn.dataset.project;
      showSSHOutput(name, 'Generating key...');
      const resp = await fetch('/api/ssh-key-operation', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'generate-key', projectName: name }),
      });
      const data = await resp.json().catch(() => ({}));
      if (resp.ok) {
        showSSHOutput(name, `Key generated. Fingerprint: ${data.fingerprint || '(none)'}`);
        await refreshSSHPanel(name);
      } else {
        showSSHOutput(name, `Error: ${data.error || resp.statusText}`);
      }
    });
  });

  document.querySelectorAll('.ssh-delete-key-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const name = btn.dataset.project;
      if (!confirm(`Delete SSH key for project "${name}"? This cannot be undone.`)) return;
      const keyPath = `/etc/ccc/project-keys/${name}/id_ed25519`;
      showSSHOutput(name, 'Deleting...');
      const resp = await fetch('/api/ssh-key-operation', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'delete-key', keyPath }),
      });
      if (resp.ok) {
        showSSHOutput(name, 'Key deleted.');
        await refreshSSHPanel(name);
      } else {
        const data = await resp.json().catch(() => ({}));
        showSSHOutput(name, `Error: ${data.error || resp.statusText}`);
      }
    });
  });

  document.querySelectorAll('.ssh-copy-key-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const name = btn.dataset.project;
      const resp = await fetch('/api/ssh-key-operation', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'get-project-config', projectName: name }),
      });
      const data = await resp.json().catch(() => ({}));
      if (data.publicKey) {
        await navigator.clipboard.writeText(data.publicKey);
        showSSHOutput(name, 'Public key copied to clipboard.');
      } else {
        showSSHOutput(name, 'No public key available.');
      }
    });
  });

  document.querySelectorAll('.ssh-deploy-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      openDeployModal(btn.dataset.project);
    });
  });

  document.querySelectorAll('.ssh-connect-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const name = btn.dataset.project;
      const resp = await fetch('/api/ssh-key-operation', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'get-project-config', projectName: name }),
      });
      const data = await resp.json().catch(() => ({}));
      if (data.testHost && data.keyExists) {
        const keyPath = `/etc/ccc/project-keys/${name}/id_ed25519`;
        activateTerminalWithCommand(`ssh -i ${keyPath} root@${data.testHost}`);
      } else {
        showSSHOutput(name, 'No key or test host configured.');
      }
    });
  });
}

async function refreshSSHPanel(projectName) {
  let cfg = {};
  try {
    const resp = await fetch('/api/ssh-key-operation', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'get-project-config', projectName }),
    });
    if (resp.ok) {
      cfg = await resp.json().catch(() => ({}));
    } else {
      showSSHOutput(projectName, 'Failed to load SSH config.');
    }
  } catch {
    showSSHOutput(projectName, 'Network error loading SSH config.');
    return;
  }

  const fp = document.getElementById(`ssh-fp-${projectName}`);
  if (fp) fp.textContent = cfg.fingerprint || (cfg.keyExists ? '(no fingerprint)' : 'no key');

  const statusDot = fp?.previousElementSibling;
  if (statusDot) {
    statusDot.className = cfg.keyExists ? 'key-exists' : 'key-missing';
  }

  const escaped = CSS.escape(projectName);
  const deleteBtn = document.querySelector(`.ssh-delete-key-btn[data-project="${escaped}"]`);
  const copyBtn = document.querySelector(`.ssh-copy-key-btn[data-project="${escaped}"]`);
  const deployBtn = document.querySelector(`.ssh-deploy-btn[data-project="${escaped}"]`);
  const connectBtn = document.querySelector(`.ssh-connect-btn[data-project="${escaped}"]`);
  const hostInput = document.getElementById(`ssh-host-${projectName}`);
  const toggleBtn = document.querySelector(`.ssh-toggle-btn[data-project="${escaped}"]`);

  if (deleteBtn) deleteBtn.disabled = !cfg.keyExists;
  if (copyBtn) copyBtn.disabled = !cfg.keyExists;
  if (deployBtn) deployBtn.disabled = !(cfg.keyExists && cfg.testHost);
  if (connectBtn) connectBtn.disabled = !(cfg.keyExists && cfg.testHost);
  if (hostInput && cfg.testHost) hostInput.value = cfg.testHost;
  if (toggleBtn) toggleBtn.classList.toggle('ssh-has-key', !!cfg.keyExists);
}

function showSSHOutput(projectName, message) {
  const output = document.getElementById(`ssh-output-${projectName}`);
  if (!output) return;
  output.textContent = message;
  output.hidden = false;
}

function openDeployModal(projectName) {
  const modal = document.getElementById('ssh-deploy-modal');
  const desc = document.getElementById('ssh-deploy-modal-desc');
  const pwInput = document.getElementById('ssh-deploy-password');
  const errEl = document.getElementById('ssh-deploy-modal-error');
  const submitBtn = document.getElementById('ssh-deploy-modal-submit');
  const cancelBtn = document.getElementById('ssh-deploy-modal-cancel');
  if (!modal) return;

  desc.textContent = `Deploy SSH public key for project "${projectName}" to its test machine.`;
  pwInput.value = '';
  errEl.hidden = true;
  modal.hidden = false;
  pwInput.focus();

  const cleanup = () => {
    modal.hidden = true;
    submitBtn.removeEventListener('click', onSubmit);
    cancelBtn.removeEventListener('click', cleanup);
    pwInput.removeEventListener('keydown', onEnter);
  };

  const onSubmit = async () => {
    const password = pwInput.value;
    if (!password) { errEl.textContent = 'Password required.'; errEl.hidden = false; return; }
    submitBtn.disabled = true;
    submitBtn.textContent = 'Deploying...';
    errEl.hidden = true;

    const resp = await fetch('/api/ssh-key-operation', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'deploy-key', projectName, password }),
    });
    const data = await resp.json().catch(() => ({}));
    submitBtn.disabled = false;
    submitBtn.textContent = 'Deploy Key';

    if (resp.ok) {
      cleanup();
      showSSHOutput(projectName, `Deployed successfully.\n${data.output || ''}`);
    } else {
      errEl.textContent = data.error || 'Deploy failed.';
      errEl.hidden = false;
    }
  };

  const onEnter = (e) => { if (e.key === 'Enter') onSubmit(); };

  submitBtn.addEventListener('click', onSubmit);
  cancelBtn.addEventListener('click', cleanup);
  pwInput.addEventListener('keydown', onEnter);
}

function activateTerminalWithCommand(cmd) {
  selectSection('terminal');
  setTimeout(() => sendTerminalInput(cmd + '\n'), 300);
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
document.getElementById('custom-title-edit').addEventListener('click', focusHeaderMessageEditor);
document.getElementById('mobile-menu-button').addEventListener('click', toggleMobileNav);
document.getElementById('mobile-nav-overlay').addEventListener('click', closeMobileNav);
document.querySelectorAll('.sidebar button').forEach(button => {
  button.addEventListener('click', () => selectSection(button.dataset.section));
});
