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
let filePath = '';
let currentFile = '';
let terminalSocket = null;
let terminal = null;
let rawTerminalBuffer = '';
let updatePollTimer = null;

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
  const services = snapshot.services || [];
  const activeServices = services.filter(service => service.active === 'active').length;
  const totalServices = services.length;
  const cpuPercent = loadPercent(data.load?.one, data.cpu?.cores);
  const updateText = stripANSI(snapshot.updates?.agentWorkstation || '');
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
        ${gauge('CPU Load', cpuPercent, `${formatLoad(data.load)} · ${data.cpu?.cores || 1} cores`)}
        ${gauge('Memory', data.memory?.usedPercent, `${formatBytes(usedBytes(data.memory))} / ${formatBytes(data.memory?.totalBytes || 0)}`)}
        ${gauge('Disk', data.disk?.usedPercent, `${formatBytes(data.disk?.usedBytes || 0)} / ${formatBytes(data.disk?.totalBytes || 0)} on ${data.disk?.mount || '/'}`)}
      </section>

      <section class="dashboard-grid">
        <div class="dash-panel">
          <h3>Update Status</h3>
          <span class="badge ${updateBadge === 'Current' ? 'ok' : updateBadge === 'Updates available' ? 'warn' : ''}">${escapeHTML(updateBadge)}</span>
          <pre class="mini-output">${escapeHTML(firstUsefulLines(updatePanelText(updateText, updateLog), 8))}</pre>
        </div>
        <div class="dash-panel">
          <h3>Agent Configs</h3>
          <span class="badge ${presentConfigs === configs.length ? 'ok' : 'warn'}">${presentConfigs}/${configs.length} present</span>
          ${configs.map(config => `<div class="mini-row"><span>${escapeHTML(config.name)}</span><strong>${config.exists ? 'ready' : 'missing'}</strong></div>`).join('')}
        </div>
        <div class="dash-panel">
          <h3>Services</h3>
          ${services.map(service => `<div class="mini-row"><span>${escapeHTML(service.name)}</span><strong class="${service.active === 'active' ? 'ok-text' : 'warn-text'}">${escapeHTML(service.active || 'unknown')}</strong></div>`).join('')}
        </div>
        <div class="dash-panel">
          <h3>Recent Activity</h3>
          <pre class="mini-output">${escapeHTML(primaryLog || 'No recent Agent Workstation logs.')}</pre>
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
  if (!filePath) {
    filePath = snapshot.projects?.[0]?.path || '/';
  }
  return `
    <div class="file-toolbar">
      <input id="file-path" type="text" value="${escapeAttribute(filePath)}">
      <button id="browse-button" class="small-button">Open</button>
      <button id="parent-button" class="small-button">Up</button>
      <button id="file-new-file-button" class="small-button">New File</button>
      <button id="file-new-folder-button" class="small-button">New Folder</button>
    </div>
    <div class="file-browser">
      <div>
        <h3>Directory</h3>
        <div id="file-list" class="file-list">Loading...</div>
      </div>
      <div>
        <h3>Editor</h3>
        <div class="file-toolbar">
          <input id="current-file" type="text" value="${escapeAttribute(currentFile)}" placeholder="Select a file">
          <button id="save-file-button" class="small-button">Save</button>
          <button id="file-rename-button" class="small-button">Rename</button>
          <button id="file-delete-button" class="small-button danger-button">Delete</button>
        </div>
        <textarea id="file-editor" spellcheck="false"></textarea>
        <pre id="file-output" class="output" hidden></pre>
      </div>
    </div>
  `;
}

function renderUpdates() {
  const updateText = stripANSI(snapshot.updates?.agentWorkstation || '');
  const updateLog = stripANSI(snapshot.updates?.selfUpdateLog || '');
  const updateBadge = updateStatusBadge(updateText, updateLog);
  return `
    <div class="action-row">
      <button class="small-button" data-action="update-status">Refresh Agent Workstation Status</button>
      <button class="small-button" data-action="self-update">Apply Agent Workstation Update</button>
      <button class="small-button" data-action="os-update">Run OS Update</button>
    </div>
    <div class="update-state">
      <span class="badge ${updateBadge === 'Current' ? 'ok' : updateBadge === 'Updates available' || updateBadge === 'Not recorded' ? 'warn' : updateBadge === 'Update failed' ? 'fail' : ''}">${escapeHTML(updateBadge)}</span>
    </div>
    <h3>Agent Workstation</h3>
    <pre id="update-status-output" class="output">${escapeHTML(updateText || 'No Agent Workstation update status.')}</pre>
    <h3>Last Self-Update Log</h3>
    <pre id="self-update-log-output" class="output">${escapeHTML(updateLog || 'No self-update log yet.')}</pre>
    <h3>OS Packages</h3>
    <pre class="output">${escapeHTML(stripANSI(snapshot.updates?.os || 'No package update data.'))}</pre>
    <pre id="action-output" class="output" hidden></pre>
  `;
}

function renderTerminal() {
  return `
    <div class="action-row">
      <button id="terminal-connect" class="small-button">Connect</button>
      <button id="terminal-disconnect" class="small-button">Disconnect</button>
      <button id="terminal-tmux" class="small-button">tmux</button>
      <span id="terminal-status">Disconnected</span>
    </div>
    <div id="terminal-pane"></div>
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
  document.querySelectorAll('[data-service]').forEach(button => {
    button.addEventListener('click', () => controlService(button.dataset.service, button.dataset.operation));
  });
  if (section === 'terminal') {
    bindTerminal();
  }
  if (section === 'files') {
    bindFileBrowser();
  }
  if (section === 'projects') {
    bindProjects();
  }
}

async function runAction(action) {
  const output = document.getElementById('action-output');
  output.hidden = false;
  output.textContent = 'Running...';
  try {
    const result = await postJSON('/api/action', { action });
    output.textContent = stripANSI(result.output || `Exit code ${result.exitCode}`);
    if (action === 'self-update') {
      monitorSelfUpdate(output);
      return;
    }
    await loadSnapshot();
  } catch (error) {
    output.textContent = stripANSI(error.message);
  }
}

function monitorSelfUpdate(output) {
  if (updatePollTimer) {
    clearInterval(updatePollTimer);
  }
  let attempts = 0;
  output.hidden = false;
  output.textContent = 'Update started. Waiting for completion...';
  updatePollTimer = setInterval(async () => {
    attempts += 1;
    try {
      await loadSnapshot();
      const statusText = stripANSI(snapshot.updates?.agentWorkstation || '');
      const logText = stripANSI(snapshot.updates?.selfUpdateLog || '');
      const logTarget = document.getElementById('self-update-log-output');
      const statusTarget = document.getElementById('update-status-output');
      if (logTarget) logTarget.textContent = logText || 'No self-update log yet.';
      if (statusTarget) statusTarget.textContent = statusText || 'No Agent Workstation update status.';
      if (logText.includes('Self-update successful')) {
        output.textContent = 'Update finished successfully. Refreshing status...';
        clearInterval(updatePollTimer);
        updatePollTimer = null;
        await refresh();
        return;
      }
      if (logText.includes('Update script exited with errors') || logText.includes('Download failed') || logText.includes('Could not find update markers')) {
        output.textContent = 'Update failed. See Last Self-Update Log for details.';
        clearInterval(updatePollTimer);
        updatePollTimer = null;
        return;
      }
      output.textContent = `Update still running... checked ${attempts} time${attempts === 1 ? '' : 's'}.`;
    } catch (error) {
      output.textContent = `Update may be restarting Agent Workstation; reconnecting... checked ${attempts} time${attempts === 1 ? '' : 's'}.`;
    }
    if (attempts >= 120) {
      output.textContent = 'Update status is still pending after 10 minutes. Check /var/log/ccc-self-update.log.';
      clearInterval(updatePollTimer);
      updatePollTimer = null;
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

function bindFileBrowser() {
  document.getElementById('browse-button').addEventListener('click', () => {
    filePath = document.getElementById('file-path').value;
    loadFiles(filePath);
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
  document.getElementById('file-delete-button')?.addEventListener('click', deleteCurrentFile);
  loadFiles(filePath);
}

async function loadFiles(path) {
  const list = document.getElementById('file-list');
  list.textContent = 'Loading...';
  try {
    const response = await fetch(`/api/files?path=${encodeURIComponent(path)}`, { credentials: 'include' });
    const data = await response.json();
    if (!response.ok) {
      throw new Error(data.error || `Request failed with ${response.status}`);
    }
    filePath = data.path;
    document.getElementById('file-path').value = data.path;
    list.innerHTML = (data.entries || []).map(entry => `
      <button class="file-entry" data-path="${escapeAttribute(entry.path)}" data-type="${escapeAttribute(entry.type)}">
        <span>${entry.type === 'dir' ? 'dir' : 'file'}</span>
        <strong>${escapeHTML(entry.name)}</strong>
        <small>${escapeHTML(formatBytes(entry.size))}</small>
      </button>
    `).join('') || '<p>No files found.</p>';
    list.querySelectorAll('.file-entry').forEach(button => {
      button.addEventListener('click', () => {
        if (button.dataset.type === 'dir') {
          filePath = button.dataset.path;
          loadFiles(filePath);
        } else {
          openFile(button.dataset.path);
        }
      });
    });
  } catch (error) {
    list.textContent = error.message;
  }
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
  const path = document.getElementById('current-file').value;
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
    document.getElementById('current-file').value = target;
    await loadFiles(filePath);
  } catch (error) {
    output.textContent = error.message;
  }
}

async function deleteCurrentFile() {
  const path = document.getElementById('current-file').value;
  if (!path || !confirm(`Delete ${path}?`)) return;
  const output = document.getElementById('file-output');
  output.hidden = false;
  output.textContent = 'Deleting...';
  try {
    const result = await postJSON('/api/file-op', { operation: 'delete', path });
    output.textContent = result.output || 'deleted';
    currentFile = '';
    document.getElementById('current-file').value = '';
    document.getElementById('file-editor').value = '';
    await loadFiles(filePath);
  } catch (error) {
    output.textContent = error.message;
  }
}

function bindTerminal() {
  document.getElementById('terminal-connect').addEventListener('click', connectTerminal);
  document.getElementById('terminal-disconnect').addEventListener('click', disconnectTerminal);
  document.getElementById('terminal-tmux').addEventListener('click', () => sendTerminalInput('tmux\n'));
  document.getElementById('terminal-raw-send').addEventListener('click', () => {
    const input = document.getElementById('terminal-raw-input');
    sendTerminalInput(`${input.value}\n`);
    input.value = '';
  });
  connectTerminal();
}

function connectTerminal() {
  if (terminalSocket && terminalSocket.readyState === WebSocket.OPEN) return;
  const status = document.getElementById('terminal-status');
  status.textContent = 'Connecting...';
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
  terminalSocket = new WebSocket(`${scheme}://${location.host}/api/pty`);
  terminalSocket.addEventListener('open', () => {
    status.textContent = 'Connected';
    if (window.Terminal) {
      document.getElementById('terminal-fallback').hidden = true;
      terminal = new window.Terminal({ cursorBlink: true, fontSize: 13, convertEol: true });
      terminal.open(document.getElementById('terminal-pane'));
      terminal.focus();
      terminal.onData(sendTerminalInput);
      resizeTerminal();
      window.addEventListener('resize', resizeTerminal);
    } else {
      document.getElementById('terminal-fallback').hidden = false;
      document.getElementById('terminal-pane').textContent = 'xterm.js unavailable; using raw terminal fallback.';
    }
  });
  terminalSocket.addEventListener('message', event => {
    if (terminal) {
      terminal.write(event.data);
    } else {
      rawTerminalBuffer += event.data;
      const output = document.getElementById('terminal-raw-output');
      output.textContent = rawTerminalBuffer;
      output.scrollTop = output.scrollHeight;
    }
  });
  terminalSocket.addEventListener('close', () => {
    status.textContent = 'Disconnected';
  });
}

function disconnectTerminal() {
  if (terminalSocket) {
    terminalSocket.close();
    terminalSocket = null;
  }
  if (terminal) {
    terminal.dispose();
    terminal = null;
  }
}

function sendTerminalInput(data) {
  if (!terminalSocket || terminalSocket.readyState !== WebSocket.OPEN) return;
  terminalSocket.send(JSON.stringify({ type: 'input', data }));
}

function resizeTerminal() {
  if (!terminalSocket || terminalSocket.readyState !== WebSocket.OPEN || !terminal) return;
  terminalSocket.send(JSON.stringify({ type: 'resize', cols: terminal.cols || 100, rows: terminal.rows || 30 }));
}

function bindProjects() {
  document.getElementById('create-project-button').addEventListener('click', createProject);
  document.querySelectorAll('[data-project-browse]').forEach(button => {
    button.addEventListener('click', () => {
      filePath = button.dataset.projectBrowse;
      selectSection('files');
    });
  });
  document.querySelectorAll('[data-project-open]').forEach(button => {
    button.addEventListener('click', () => {
      window.open(`http://${location.hostname}:8080/?folder=${encodeURIComponent(button.dataset.projectOpen)}`, '_blank');
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

function updatePanelText(statusText, logText) {
  const successLine = logText.split('\n').find(line => line.includes('Self-update successful'));
  return [successLine, statusText].filter(Boolean).join('\n');
}

function gauge(label, value, detail) {
  const percent = clampPercent(value);
  return `
    <div class="gauge-card">
      <div class="gauge" style="--value:${percent}">
        <div class="gauge-inner">
          <strong>${Number.isFinite(percent) ? percent.toFixed(0) : 0}%</strong>
          <span>${escapeHTML(label)}</span>
        </div>
      </div>
      <p>${escapeHTML(detail || '')}</p>
    </div>
  `;
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

function stripANSI(value) {
  return String(value || '').replace(/(?:\x1b)?\[[0-9;]*m/g, '');
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
