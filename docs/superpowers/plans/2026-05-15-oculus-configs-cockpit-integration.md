# oculus-configs + Prism CCC Cockpit Plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate oculus-configs into CCC provisioning and replace the stock Cockpit UI with a native Prism-dark plugin covering all configure.py features.

**Architecture:** oculus-configs is cloned to `/opt/oculus-configs` during provisioning; its CLAUDE.md, rules, templates, and Codex/Gemini skill files are copied into place. The Cockpit plugin (`/usr/share/cockpit/ccc/`) is a single self-contained `index.html` with Prism-dark CSS, six tabs backed by `cockpit.file()` and `cockpit.spawn()`, and no external port or Python service. The plugin is developed in `docs/cockpit-plugin/index.html` with a mock cockpit, then embedded as a heredoc in `claude-code-commander.sh`.

**Tech Stack:** Bash (provisioner), vanilla JS + cockpit.js (plugin), Prism-dark CSS (design tokens from spec)

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `claude-code-commander.sh` | Modify | Four zones: step 18 (replace), step 24 MOTD (edit), step 27 Cockpit (add plugin block), step count comment |
| `docs/cockpit-plugin/manifest.json` | Create | Cockpit plugin declaration — dev reference |
| `docs/cockpit-plugin/mock-cockpit.js` | Create | Mock cockpit API for browser-based dev testing |
| `docs/cockpit-plugin/index.html` | Create | The full plugin (built across Tasks 4–9), then embedded into bash script in Task 10 |

---

## Task 1: Replace step 18 in bash script (remove CLAUDE.md heredoc, add oculus-configs)

**Files:**
- Modify: `claude-code-commander.sh` lines 618–677

- [ ] **Step 1: Verify current state — syntax check and baseline grep**

```bash
bash -n claude-code-commander.sh && echo "syntax OK"
grep -n 'step 18\|CLAUDEMD\|Claude Code Workspace' claude-code-commander.sh
```

Expected: `step 18 "CLAUDE.md"` at line 619, `CLAUDEMD` heredoc delimiter visible.

- [ ] **Step 2: Replace the entire step 18 block**

Replace lines 618–677 (from `# ── CLAUDE.md` through `sudo -u claude-code mkdir -p /home/claude-code/.claude/skills`) with the following:

```bash
# ── oculus-configs ────────────────────────────────────────────────────────────
step 18 "oculus-configs"
sudo -u claude-code mkdir -p /home/claude-code/projects
git clone --depth 1 https://github.com/oculus-pllx/oculus-configs /opt/oculus-configs 2>&1 | sed 's/^/  /'
chown -R claude-code:claude-code /opt/oculus-configs
# CLAUDE.md
cp /opt/oculus-configs/claude/CLAUDE.md /home/claude-code/.claude/CLAUDE.md \
  || warn "oculus-configs: CLAUDE.md not found, skipping"
# rules/
if [[ -d /opt/oculus-configs/claude/rules ]]; then
  sudo -u claude-code cp -r /opt/oculus-configs/claude/rules/. /home/claude-code/.claude/rules/
else
  warn "oculus-configs: rules/ not found, skipping"
fi
# templates/
sudo -u claude-code mkdir -p /home/claude-code/Templates
if [[ -d /opt/oculus-configs/templates ]]; then
  sudo -u claude-code cp -r /opt/oculus-configs/templates/. /home/claude-code/Templates/
else
  warn "oculus-configs: templates/ not found, skipping"
fi
# Codex skills
sudo -u claude-code mkdir -p /home/claude-code/.codex
sudo -u claude-code cp /opt/oculus-configs/codex/skills/AGENTS.md \
  /home/claude-code/.codex/AGENTS.md 2>/dev/null \
  || warn "oculus-configs: codex/skills/AGENTS.md not found, skipping"
# Gemini skills
sudo -u claude-code mkdir -p /home/claude-code/.gemini
sudo -u claude-code cp /opt/oculus-configs/gemini/skills/GEMINI.md \
  /home/claude-code/.gemini/GEMINI.md 2>/dev/null \
  || warn "oculus-configs: gemini/skills/GEMINI.md not found, skipping"
sudo -u claude-code mkdir -p /home/claude-code/.claude/skills
```

- [ ] **Step 3: Verify replacement**

```bash
bash -n claude-code-commander.sh && echo "syntax OK"
grep -n 'step 18' claude-code-commander.sh
# Expected: step 18 "oculus-configs"
grep -n 'Claude Code Workspace\|CLAUDEMD' claude-code-commander.sh
# Expected: no output (heredoc gone)
grep -n 'oculus-configs' claude-code-commander.sh | head -5
# Expected: clone command visible
```

- [ ] **Step 4: Commit**

```bash
git add claude-code-commander.sh
git commit -m "feat: replace CLAUDE.md heredoc with oculus-configs provisioning step"
```

---

## Task 2: Update MOTD (step 24)

**Files:**
- Modify: `claude-code-commander.sh` around line 1648 (step 24 MOTD block)

- [ ] **Step 1: Find the Cockpit MOTD line**

```bash
grep -n 'Cockpit\|9090' claude-code-commander.sh | grep echo
```

Note the exact line(s) that reference Cockpit in the MOTD heredoc.

- [ ] **Step 2: Update the Cockpit description line**

Find:
```bash
echo -e "  ${C}https://\${IP}:9090${N}  Cockpit — system monitoring, file manager"
```

Replace with:
```bash
echo -e "  ${C}https://\${IP}:9090${N}  Cockpit — config, projects, MCP, updates"
```

- [ ] **Step 3: Remove ccc-fix-cockpit-updates and ccc-verify-cockpit-updates from MOTD display**

In the MOTD heredoc, find and remove these two lines (the commands remain installed, just not shown in MOTD):

```bash
echo -e "  ${C}ccc-fix-cockpit-updates${N}   Fix Cockpit offline update cache error"
echo -e "  ${C}ccc-verify-cockpit-updates${N} Check Cockpit GUI update readiness"
```

- [ ] **Step 4: Verify and commit**

```bash
bash -n claude-code-commander.sh && echo "syntax OK"
grep -A1 -B1 '9090' claude-code-commander.sh | grep -A1 -B1 'echo'
git add claude-code-commander.sh
git commit -m "feat: update MOTD to reflect Prism CCC Cockpit plugin"
```

---

## Task 3: Create Cockpit plugin dev scaffold

**Files:**
- Create: `docs/cockpit-plugin/manifest.json`
- Create: `docs/cockpit-plugin/mock-cockpit.js`
- Create: `docs/cockpit-plugin/index.html` (skeleton only — tabs added in Tasks 4–9)

- [ ] **Step 1: Write manifest.json**

```bash
cat > docs/cockpit-plugin/manifest.json << 'EOF'
{
  "version": 0,
  "name": "ccc",
  "priority": 1,
  "menu": {
    "index": {
      "label": "Claude Code Commander",
      "order": 0
    }
  }
}
EOF
```

- [ ] **Step 2: Write mock-cockpit.js**

```bash
cat > docs/cockpit-plugin/mock-cockpit.js << 'EOF'
// Mock cockpit.js for local dev — replace with /cockpit/base1/cockpit.js in production
const _files = {
  '/home/claude-code/.claude/CLAUDE.md': '# Claude Code Workspace\n\nMock CLAUDE.md content.',
  '/home/claude-code/.claude/mcp.json': '{"mcpServers":{"github":{"command":"npx","args":["-y","@modelcontextprotocol/server-github"]}}}',
  '/home/claude-code/.claude/settings.json': '{"plugins":{"enabled":["superpowers@claude-plugins-official","frontend-design@claude-plugins-official"]},"permissions":{"allow":[]}}',
  '/home/claude-code/.bashrc': '# mock bashrc\nexport GITHUB_TOKEN="ghp_mock"\n',
};
function _spawn(args) {
  const cmd = args.join(' ');
  if (cmd.includes('test -f') && cmd.includes('CLAUDE.md')) return Promise.resolve('');
  if (cmd.includes('ls') && cmd.includes('rules')) return Promise.resolve('code-quality.md\nplugin-usage.md');
  if (cmd.includes('ls -1') && cmd.includes('projects')) return Promise.resolve('my-project\nhello-world');
  if (cmd.includes('ls -1') && cmd.includes('Templates')) return Promise.resolve('claude-code-starter');
  if (cmd.includes('wc -l')) return Promise.resolve('2');
  if (cmd.includes('systemctl is-active code-server')) return Promise.resolve('active');
  if (cmd.includes('which claude')) return Promise.resolve('/usr/local/bin/claude');
  if (cmd.includes('hostname -I')) return Promise.resolve('192.168.1.100 ');
  if (cmd.includes('ccc-update-status')) return Promise.resolve('Installed: abc1234 (2026-05-10)\nLatest:    def5678 (2026-05-15)\n2 commits behind\n  • Add update status command\n  • Remove command center');
  if (cmd.includes('git') && cmd.includes('fetch')) return Promise.resolve('');
  if (cmd.includes('git') && cmd.includes('log') && cmd.includes('HEAD..')) return Promise.resolve('def5678 Add Prism Cockpit plugin\nabc9999 Update CLAUDE.md');
  if (cmd.includes('mkdir') || cmd.includes('git init') || cmd.includes('cp ')) return Promise.resolve('');
  return Promise.resolve('');
}
const cockpit = {
  file: (path) => ({
    read: () => Promise.resolve(_files[path] ?? null),
    replace: (content) => { _files[path] = content; return Promise.resolve(); },
  }),
  spawn: (args) => _spawn(args),
  user: () => Promise.resolve({ name: 'claude-code', home: '/home/claude-code' }),
};
EOF
```

- [ ] **Step 3: Write skeleton index.html**

```bash
cat > docs/cockpit-plugin/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Claude Code Commander</title>
  <style>
    /* CSS added in Task 4 */
  </style>
</head>
<body>
  <nav id="nav"><!-- nav added in Task 4 --></nav>
  <main>
    <div id="tab-overview" class="tab-panel active"><p style="color:#fff;padding:20px">Overview — coming in Task 4</p></div>
    <div id="tab-projects" class="tab-panel"><p style="color:#fff;padding:20px">Projects — coming in Task 5</p></div>
    <div id="tab-claude" class="tab-panel"><p style="color:#fff;padding:20px">CLAUDE.md — coming in Task 6</p></div>
    <div id="tab-mcp" class="tab-panel"><p style="color:#fff;padding:20px">MCP — coming in Task 7</p></div>
    <div id="tab-plugins" class="tab-panel"><p style="color:#fff;padding:20px">Plugins — coming in Task 8</p></div>
    <div id="tab-updates" class="tab-panel"><p style="color:#fff;padding:20px">Updates — coming in Task 9</p></div>
  </main>
  <div id="toast"></div>
  <div class="modal-overlay" id="modal">
    <div class="modal">
      <h3 id="modal-title">Confirm</h3>
      <p id="modal-body"></p>
      <div class="modal-buttons">
        <button onclick="modalResolve(false)">Cancel</button>
        <button onclick="modalResolve(true)" id="modal-ok">Confirm</button>
      </div>
    </div>
  </div>
  <!-- Dev: swap for /cockpit/base1/cockpit.js when embedding in bash script -->
  <script src="mock-cockpit.js"></script>
  <script>
    function showTab(name) {
      document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
      document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
      document.getElementById('tab-' + name).classList.add('active');
      document.querySelector(`.tab-btn[data-tab="${name}"]`)?.classList.add('active');
      tabLoaders[name]?.();
    }
    const tabLoaders = {};
  </script>
</body>
</html>
HTMLEOF
```

- [ ] **Step 4: Open in browser to verify scaffold loads**

```bash
# Open docs/cockpit-plugin/index.html directly in your browser
# You should see a white/black page with placeholder tab text — no errors in console
```

- [ ] **Step 5: Commit scaffold**

```bash
git add docs/cockpit-plugin/
git commit -m "feat: add Cockpit plugin dev scaffold (manifest, mock, skeleton)"
```

---

## Task 4: Plugin — Prism CSS + nav bar + tab routing + Overview tab

**Files:**
- Modify: `docs/cockpit-plugin/index.html` — replace `<style>` block, replace `<nav>`, add Overview panel HTML, add Overview JS

- [ ] **Step 1: Replace `<style>` block with full Prism CSS**

Replace the `/* CSS added in Task 4 */` comment inside `<style>` with:

```css
:root {
  --bg:#0b0f1a; --nav-bg:#0d1220; --card-bg:#0f1624; --surface2:#141c2e;
  --border:#1a2233; --border2:#222d42; --text:#cdd6f4; --muted:#4a6080;
  --muted2:#2a3a52; --cyan:#00e5ff; --green:#00ff88; --yellow:#f5c518;
  --purple:#a78bfa; --orange:#fb923c; --red:#f38ba8; --mono:'Courier New',monospace;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:system-ui,sans-serif;height:100vh;display:flex;flex-direction:column;overflow:hidden}
nav{background:var(--nav-bg);border-bottom:1px solid var(--border);display:flex;align-items:center;padding:0 20px;height:44px;flex-shrink:0;gap:2px}
.logo{display:flex;align-items:center;gap:8px;margin-right:20px}
.logo-tri{width:16px;height:16px;background:linear-gradient(135deg,var(--cyan),#7c3aed);clip-path:polygon(50% 0%,100% 100%,0% 100%)}
.logo-text{font-family:var(--mono);font-size:11px;font-weight:700;letter-spacing:2px;color:var(--cyan)}
.tab-btn{height:44px;padding:0 13px;font-family:var(--mono);font-size:10px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:var(--muted);background:none;border:none;border-bottom:2px solid transparent;cursor:pointer;transition:color .15s}
.tab-btn:hover{color:var(--text)}
.tab-btn.active{color:var(--cyan);border-bottom-color:var(--cyan)}
.nav-right{margin-left:auto;font-family:var(--mono);font-size:10px;color:var(--muted2)}
main{flex:1;overflow-y:auto;padding:24px}
.tab-panel{display:none}
.tab-panel.active{display:block}
.section-label{font-family:var(--mono);font-size:9px;font-weight:700;letter-spacing:1.8px;text-transform:uppercase;color:var(--muted2);margin-bottom:10px}
.card-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:24px}
.stat-card{background:var(--card-bg);border:1px solid var(--border);border-left:3px solid;border-radius:3px;padding:12px 14px}
.stat-label{font-family:var(--mono);font-size:9px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:var(--muted);margin-bottom:6px}
.stat-value{font-family:var(--mono);font-size:16px;font-weight:700}
.pills{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:24px}
.pill{display:flex;align-items:center;gap:6px;padding:5px 10px;border:1px solid var(--border);border-radius:2px;font-family:var(--mono);font-size:10px;color:var(--muted)}
.dot{width:6px;height:6px;border-radius:50%;background:var(--muted2)}
.dot.on{background:var(--green);box-shadow:0 0 4px var(--green)}
.dot.off{background:var(--red)}
.link-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin-bottom:24px}
.quick-link{background:var(--card-bg);border:1px solid var(--border);border-radius:3px;padding:10px 12px;cursor:pointer;text-decoration:none;display:block}
.quick-link:hover{border-color:var(--border2)}
.quick-link-title{font-family:var(--mono);font-size:11px;color:var(--cyan);margin-bottom:3px}
.quick-link-sub{font-family:var(--mono);font-size:9px;color:var(--muted2)}
.btn{padding:7px 14px;border-radius:2px;font-family:var(--mono);font-size:11px;font-weight:700;letter-spacing:.5px;cursor:pointer;border:1px solid;transition:opacity .15s}
.btn:hover{opacity:.85}
.btn-primary{background:var(--cyan);color:#000;border-color:var(--cyan)}
.btn-secondary{background:transparent;color:var(--text);border-color:var(--border2)}
.btn-danger{background:transparent;color:var(--orange);border-color:var(--orange)}
.btn-sm{padding:4px 10px;font-size:10px}
#toast{position:fixed;bottom:20px;right:20px;padding:10px 16px;border-radius:3px;font-family:var(--mono);font-size:12px;background:var(--card-bg);border:1px solid var(--border);color:var(--text);transform:translateY(60px);opacity:0;transition:all .2s;z-index:1000}
#toast.show{transform:translateY(0);opacity:1}
#toast.error{border-color:var(--orange);color:var(--orange)}
#toast.success{border-color:var(--green);color:var(--green)}
input,textarea,select{background:var(--card-bg);border:1px solid var(--border);border-radius:2px;color:var(--text);padding:8px 10px;font-family:var(--mono);font-size:12px;width:100%}
input:focus,textarea:focus,select:focus{outline:none;border-color:var(--cyan)}
label{font-family:var(--mono);font-size:10px;letter-spacing:.5px;color:var(--muted);display:block;margin-bottom:4px}
.form-group{margin-bottom:14px}
table{width:100%;border-collapse:collapse;margin-bottom:16px}
th{text-align:left;padding:8px 12px;background:var(--surface2);border:1px solid var(--border);font-family:var(--mono);font-size:9px;letter-spacing:1px;text-transform:uppercase;color:var(--muted)}
td{padding:8px 12px;border:1px solid var(--border);font-family:var(--mono);font-size:12px}
.project-list{list-style:none;margin-bottom:16px}
.project-item{display:flex;align-items:center;justify-content:space-between;padding:10px 12px;border:1px solid var(--border);border-radius:3px;margin-bottom:6px;background:var(--card-bg)}
.project-name{font-family:var(--mono);font-size:12px}
.wizard-steps{display:flex;gap:4px;margin-bottom:20px}
.wizard-step{flex:1;height:3px;background:var(--border2);border-radius:2px;transition:background .2s}
.wizard-step.done{background:var(--cyan)}
.wizard-step.active{background:var(--cyan);opacity:.5}
.toggle{display:flex;align-items:center;justify-content:space-between;padding:10px 12px;border:1px solid var(--border);border-radius:3px;margin-bottom:6px;background:var(--card-bg)}
.toggle-switch{width:36px;height:20px;background:var(--border2);border-radius:10px;position:relative;cursor:pointer;transition:background .2s;flex-shrink:0}
.toggle-switch.on{background:var(--cyan)}
.toggle-thumb{position:absolute;top:3px;left:3px;width:14px;height:14px;border-radius:50%;background:var(--muted);transition:left .2s,background .2s}
.toggle-switch.on .toggle-thumb{left:19px;background:#000}
.output-box{background:#060a12;border:1px solid var(--border);border-radius:3px;padding:12px;font-family:var(--mono);font-size:11px;color:#8ab4d4;white-space:pre-wrap;margin-bottom:16px;max-height:200px;overflow-y:auto}
#claude-textarea{height:calc(100vh - 160px);resize:none;font-size:13px;line-height:1.6}
.modal-overlay{display:none;position:fixed;inset:0;background:#00000088;z-index:500;align-items:center;justify-content:center}
.modal-overlay.show{display:flex}
.modal{background:var(--card-bg);border:1px solid var(--border2);border-radius:4px;padding:24px;max-width:400px;width:90%}
.modal h3{font-size:14px;font-weight:700;margin-bottom:10px}
.modal p{font-size:13px;color:var(--muted);margin-bottom:20px}
.modal-buttons{display:flex;gap:8px;justify-content:flex-end}
.cyan{color:var(--cyan)} .green{color:var(--green)} .yellow{color:var(--yellow)}
.purple{color:var(--purple)} .orange{color:var(--orange)}
```

- [ ] **Step 2: Replace `<nav id="nav">` with full nav bar HTML**

```html
<nav>
  <div class="logo">
    <div class="logo-tri"></div>
    <div class="logo-text">CCC</div>
  </div>
  <button class="tab-btn active" data-tab="overview" onclick="showTab('overview')">Overview</button>
  <button class="tab-btn" data-tab="projects" onclick="showTab('projects')">Projects</button>
  <button class="tab-btn" data-tab="claude" onclick="showTab('claude')">Claude.md</button>
  <button class="tab-btn" data-tab="mcp" onclick="showTab('mcp')">MCP</button>
  <button class="tab-btn" data-tab="plugins" onclick="showTab('plugins')">Plugins</button>
  <button class="tab-btn" data-tab="updates" onclick="showTab('updates')">Updates</button>
  <div class="nav-right" id="nav-user">claude-code@ccc</div>
</nav>
```

- [ ] **Step 3: Replace Overview tab panel HTML**

Replace `<div id="tab-overview" class="tab-panel active">...</div>` with:

```html
<div id="tab-overview" class="tab-panel active">
  <div class="section-label">Config Status</div>
  <div class="card-grid">
    <div class="stat-card" style="border-left-color:var(--cyan)">
      <div class="stat-label">CLAUDE.md</div>
      <div class="stat-value cyan" id="s-claude">—</div>
    </div>
    <div class="stat-card" style="border-left-color:var(--green)">
      <div class="stat-label">Rules</div>
      <div class="stat-value green" id="s-rules">—</div>
    </div>
    <div class="stat-card" style="border-left-color:var(--yellow)">
      <div class="stat-label">MCP Servers</div>
      <div class="stat-value yellow" id="s-mcp">—</div>
    </div>
    <div class="stat-card" style="border-left-color:var(--purple)">
      <div class="stat-label">Plugins</div>
      <div class="stat-value purple" id="s-plugins">—</div>
    </div>
  </div>
  <div class="section-label">Services</div>
  <div class="pills">
    <div class="pill"><span class="dot" id="dot-code-server"></span>code-server :8080</div>
    <div class="pill"><span class="dot on"></span>cockpit :9090</div>
    <div class="pill"><span class="dot" id="dot-claude"></span>claude</div>
  </div>
  <div class="section-label">Quick Links</div>
  <div class="link-grid">
    <a class="quick-link" id="vscode-link" href="#" target="_blank">
      <div class="quick-link-title">Web VS Code ↗</div>
      <div class="quick-link-sub">code editor + terminal</div>
    </a>
    <a class="quick-link" href="#" onclick="showTab('projects');return false">
      <div class="quick-link-title">New Project →</div>
      <div class="quick-link-sub">wizard → git → github</div>
    </a>
  </div>
</div>
```

- [ ] **Step 4: Add Overview JS and shared utilities inside `<script>` block**

Replace the entire `<script>` block (after the mock script tag) with:

```html
<script src="mock-cockpit.js"></script>
<script>
// ── Shared utilities ───────────────────────────────────────────────────────
let _toastTimer;
function showToast(msg, type = 'success') {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'show ' + type;
  clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => { t.className = ''; }, 3000);
}

let _modalResolve;
function confirm(title, body, okLabel = 'Confirm') {
  return new Promise(resolve => {
    document.getElementById('modal-title').textContent = title;
    document.getElementById('modal-body').textContent = body;
    document.getElementById('modal-ok').textContent = okLabel;
    document.getElementById('modal').classList.add('show');
    _modalResolve = result => {
      document.getElementById('modal').classList.remove('show');
      resolve(result);
    };
  });
}
function modalResolve(result) { _modalResolve?.(result); }

const tabLoaders = {};
function showTab(name) {
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.getElementById('tab-' + name).classList.add('active');
  document.querySelector(`.tab-btn[data-tab="${name}"]`)?.classList.add('active');
  tabLoaders[name]?.();
}

// ── Overview ───────────────────────────────────────────────────────────────
let _ip = '';
async function getIP() {
  if (_ip) return _ip;
  try { const s = await cockpit.spawn(['hostname', '-I']); _ip = s.trim().split(' ')[0]; }
  catch { _ip = location.hostname; }
  return _ip;
}

async function loadOverview() {
  // CLAUDE.md present?
  try {
    await cockpit.spawn(['test', '-f', '/home/claude-code/.claude/CLAUDE.md'], {err: 'ignore'});
    document.getElementById('s-claude').textContent = '✓ OK';
  } catch {
    document.getElementById('s-claude').textContent = '✗ missing';
    document.getElementById('s-claude').className = 'stat-value orange';
  }
  // Rules count
  try {
    const n = await cockpit.spawn(['bash', '-c', 'ls /home/claude-code/.claude/rules/ 2>/dev/null | wc -l']);
    document.getElementById('s-rules').textContent = n.trim() + ' files';
  } catch { document.getElementById('s-rules').textContent = '0 files'; }
  // MCP server count
  try {
    const raw = await cockpit.file('/home/claude-code/.claude/mcp.json').read();
    const mcp = JSON.parse(raw || '{"mcpServers":{}}');
    document.getElementById('s-mcp').textContent = Object.keys(mcp.mcpServers || {}).length + ' servers';
  } catch { document.getElementById('s-mcp').textContent = '0 servers'; }
  // Plugin count
  try {
    const raw = await cockpit.file('/home/claude-code/.claude/settings.json').read();
    const s = JSON.parse(raw || '{}');
    const count = Array.isArray(s.plugins?.enabled) ? s.plugins.enabled.length : '?';
    document.getElementById('s-plugins').textContent = count + ' enabled';
  } catch { document.getElementById('s-plugins').textContent = '? enabled'; }
  // Service dots
  cockpit.spawn(['systemctl', 'is-active', 'code-server'], {err: 'ignore'})
    .then(s => document.getElementById('dot-code-server').className = 'dot ' + (s.trim() === 'active' ? 'on' : 'off'))
    .catch(() => { document.getElementById('dot-code-server').className = 'dot off'; });
  cockpit.spawn(['bash', '-c', 'which claude 2>/dev/null'], {err: 'ignore'})
    .then(p => document.getElementById('dot-claude').className = 'dot ' + (p.trim() ? 'on' : 'off'))
    .catch(() => { document.getElementById('dot-claude').className = 'dot off'; });
  // VS Code link
  getIP().then(ip => { document.getElementById('vscode-link').href = 'http://' + ip + ':8080'; });
}
tabLoaders.overview = loadOverview;

// ── Init ────────────────────────────────────────────────────────────────────
cockpit.user().then(u => {
  document.getElementById('nav-user').textContent = u.name + '@' + location.hostname;
}).catch(() => {});
loadOverview();
</script>
```

- [ ] **Step 5: Open in browser — verify Overview tab loads without console errors**

Open `docs/cockpit-plugin/index.html` in your browser. You should see:
- Prism dark background, cyan nav bar, six tab buttons
- Overview tab: four stat cards populated (CLAUDE.md ✓ OK, Rules 2 files, MCP Servers 1, Plugins 2 enabled)
- Service pills: code-server green, cockpit green, claude green
- Quick link cards visible

Check browser console — no errors.

- [ ] **Step 6: Commit**

```bash
git add docs/cockpit-plugin/index.html
git commit -m "feat: Cockpit plugin — Prism CSS + nav + Overview tab"
```

---

## Task 5: Plugin — Projects tab

**Files:**
- Modify: `docs/cockpit-plugin/index.html`

- [ ] **Step 1: Replace Projects tab panel HTML**

Replace `<div id="tab-projects" class="tab-panel">...</div>` with:

```html
<div id="tab-projects" class="tab-panel">
  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
    <div class="section-label" style="margin:0">Projects</div>
    <button class="btn btn-primary btn-sm" onclick="showWizard()">+ New Project</button>
  </div>
  <ul class="project-list" id="project-list">
    <li style="padding:12px;color:var(--muted);font-family:var(--mono);font-size:11px">Loading...</li>
  </ul>
  <div id="wizard" style="display:none;background:var(--card-bg);border:1px solid var(--border);border-radius:4px;padding:20px">
    <div class="wizard-steps">
      <div class="wizard-step active" id="ws-1"></div>
      <div class="wizard-step" id="ws-2"></div>
      <div class="wizard-step" id="ws-3"></div>
      <div class="wizard-step" id="ws-4"></div>
    </div>
    <div id="wizard-content"></div>
    <div style="display:flex;gap:8px;margin-top:16px">
      <button class="btn btn-secondary btn-sm" onclick="hideWizard()">Cancel</button>
      <button class="btn btn-primary btn-sm" id="wizard-next-btn" onclick="wizardNext()">Next →</button>
    </div>
  </div>
</div>
```

- [ ] **Step 2: Add Projects JS before `// ── Init` comment**

```javascript
// ── Projects ───────────────────────────────────────────────────────────────
async function loadProjects() {
  const list = document.getElementById('project-list');
  try {
    const out = await cockpit.spawn(['bash', '-c', 'ls -1 /home/claude-code/projects/ 2>/dev/null']);
    const projects = out.trim().split('\n').filter(p => p);
    const ip = await getIP();
    if (!projects.length) {
      list.innerHTML = '<li style="padding:12px;color:var(--muted);font-family:var(--mono);font-size:11px">No projects yet.</li>';
      return;
    }
    list.innerHTML = projects.map(p => `
      <li class="project-item">
        <span class="project-name">${p}</span>
        <a class="btn btn-secondary btn-sm"
           href="http://${ip}:8080/?folder=/home/claude-code/projects/${encodeURIComponent(p)}"
           target="_blank">Open in VS Code ↗</a>
      </li>`).join('');
  } catch {
    list.innerHTML = '<li style="padding:12px;color:var(--orange);font-family:var(--mono);font-size:11px">Error loading projects.</li>';
  }
}
tabLoaders.projects = loadProjects;

const _wiz = { step: 1, name: '', location: '', template: '', remote: '' };

function showWizard() {
  Object.assign(_wiz, { step: 1, name: '', location: '', template: '', remote: '' });
  document.getElementById('wizard').style.display = 'block';
  renderWizardStep();
}
function hideWizard() { document.getElementById('wizard').style.display = 'none'; }

async function renderWizardStep() {
  const s = _wiz.step;
  ['ws-1','ws-2','ws-3','ws-4'].forEach((id, i) => {
    document.getElementById(id).className =
      'wizard-step' + (i + 1 < s ? ' done' : i + 1 === s ? ' active' : '');
  });
  document.getElementById('wizard-next-btn').textContent = s === 4 ? 'Create Project' : 'Next →';
  const labels = ['Name','Location','Template','GitHub Remote'];
  let html = `<div class="section-label" style="margin-bottom:10px">Step ${s} of 4 — ${labels[s-1]}</div>`;
  if (s === 1) {
    html += `<div class="form-group"><label>Project Name</label>
      <input id="w-name" placeholder="my-project" value="${_wiz.name}"></div>`;
  } else if (s === 2) {
    html += `<div class="form-group"><label>Location</label>
      <input id="w-loc" value="${_wiz.location || '/home/claude-code/projects/' + _wiz.name}"></div>`;
  } else if (s === 3) {
    let opts = '<option value="">— None (blank project) —</option>';
    try {
      const out = await cockpit.spawn(['bash', '-c', 'ls -1 /home/claude-code/Templates/ 2>/dev/null']);
      out.trim().split('\n').filter(t => t).forEach(t => {
        opts += `<option value="${t}" ${_wiz.template === t ? 'selected' : ''}>${t}</option>`;
      });
    } catch {}
    html += `<div class="form-group"><label>Starter Template (optional)</label>
      <select id="w-tpl">${opts}</select></div>`;
  } else {
    html += `<div class="form-group"><label>GitHub Remote (optional — leave blank to skip)</label>
      <input id="w-remote" placeholder="username/repo-name" value="${_wiz.remote}"></div>
      <div style="font-family:var(--mono);font-size:9px;color:var(--muted2)">Runs: gh repo create &lt;name&gt; --private --source=. --push</div>`;
  }
  document.getElementById('wizard-content').innerHTML = html;
}

async function wizardNext() {
  const s = _wiz.step;
  if (s === 1) {
    const name = document.getElementById('w-name').value.trim();
    if (!name || name.includes('/') || name.includes('..') || name.startsWith('.')) {
      showToast('Invalid project name', 'error'); return;
    }
    _wiz.name = name; _wiz.step = 2; renderWizardStep();
  } else if (s === 2) {
    const loc = document.getElementById('w-loc').value.trim();
    if (!loc) { showToast('Location required', 'error'); return; }
    _wiz.location = loc; _wiz.step = 3; renderWizardStep();
  } else if (s === 3) {
    _wiz.template = document.getElementById('w-tpl').value;
    _wiz.step = 4; renderWizardStep();
  } else {
    _wiz.remote = document.getElementById('w-remote').value.trim();
    await createProject();
  }
}

async function createProject() {
  const { name, location, template, remote } = _wiz;
  const btn = document.getElementById('wizard-next-btn');
  btn.textContent = 'Creating...'; btn.disabled = true;
  try {
    await cockpit.spawn(['mkdir', '-p', location]);
    await cockpit.spawn(['git', '-C', location, 'init']);
    if (template) {
      await cockpit.spawn(['bash', '-c', 'cp -r "$1"/. "$2"/', '_',
        '/home/claude-code/Templates/' + template, location]);
    }
    if (remote) {
      await cockpit.spawn(['bash', '-c', 'cd "$1" && gh repo create "$2" --private --source=. --push',
        '_', location, remote]);
    }
    showToast('Project created: ' + name);
    hideWizard(); loadProjects();
  } catch (err) {
    showToast('Error: ' + err.message, 'error');
  } finally {
    btn.textContent = 'Create Project'; btn.disabled = false;
  }
}
```

- [ ] **Step 3: Open in browser — verify Projects tab**

Click the Projects tab. You should see:
- "my-project" and "hello-world" listed (from mock)
- Each has an "Open in VS Code ↗" link
- "+ New Project" opens the 4-step wizard
- Wizard step 1: type a name → Next → step 2 shows location pre-filled → step 3 shows template dropdown → step 4 shows GitHub remote field

- [ ] **Step 4: Commit**

```bash
git add docs/cockpit-plugin/index.html
git commit -m "feat: Cockpit plugin — Projects tab with wizard"
```

---

## Task 6: Plugin — CLAUDE.md tab

**Files:**
- Modify: `docs/cockpit-plugin/index.html`

- [ ] **Step 1: Replace CLAUDE.md tab panel HTML**

```html
<div id="tab-claude" class="tab-panel">
  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
    <div class="section-label" style="margin:0">CLAUDE.md</div>
    <div style="display:flex;gap:8px">
      <button class="btn btn-secondary btn-sm" onclick="reloadFromOculus()">↺ Reload from oculus-configs</button>
      <button class="btn btn-primary btn-sm" onclick="saveClaude()">Save</button>
    </div>
  </div>
  <textarea id="claude-textarea" placeholder="Loading..."></textarea>
</div>
```

- [ ] **Step 2: Add CLAUDE.md JS before `// ── Init` comment**

```javascript
// ── CLAUDE.md ──────────────────────────────────────────────────────────────
async function loadClaude() {
  try {
    const content = await cockpit.file('/home/claude-code/.claude/CLAUDE.md').read();
    document.getElementById('claude-textarea').value = content || '';
  } catch (err) {
    showToast('Error reading CLAUDE.md: ' + err.message, 'error');
  }
}
tabLoaders.claude = loadClaude;

async function saveClaude() {
  try {
    await cockpit.file('/home/claude-code/.claude/CLAUDE.md')
      .replace(document.getElementById('claude-textarea').value);
    showToast('CLAUDE.md saved');
  } catch (err) {
    showToast('Error saving: ' + err.message, 'error');
  }
}

async function reloadFromOculus() {
  const ok = await confirm(
    'Reload CLAUDE.md',
    'Overwrite your current CLAUDE.md with the version from oculus-configs? Your edits will be lost.',
    'Overwrite'
  );
  if (!ok) return;
  try {
    await cockpit.spawn(['cp',
      '/opt/oculus-configs/claude/CLAUDE.md',
      '/home/claude-code/.claude/CLAUDE.md']);
    await loadClaude();
    showToast('Reloaded from oculus-configs');
  } catch (err) {
    showToast('Error: ' + err.message, 'error');
  }
}
```

- [ ] **Step 3: Open in browser — verify CLAUDE.md tab**

Click the Claude.md tab. You should see:
- Textarea filled with mock CLAUDE.md content
- "Save" button shows success toast
- "↺ Reload from oculus-configs" shows confirmation modal then updates textarea

- [ ] **Step 4: Commit**

```bash
git add docs/cockpit-plugin/index.html
git commit -m "feat: Cockpit plugin — CLAUDE.md editor tab"
```

---

## Task 7: Plugin — MCP tab

**Files:**
- Modify: `docs/cockpit-plugin/index.html`

- [ ] **Step 1: Replace MCP tab panel HTML**

```html
<div id="tab-mcp" class="tab-panel">
  <div class="section-label">MCP Servers</div>
  <table>
    <thead><tr><th>Name</th><th>Command</th><th style="width:80px"></th></tr></thead>
    <tbody id="mcp-table-body">
      <tr><td colspan="3" style="color:var(--muted)">Loading...</td></tr>
    </tbody>
  </table>
  <div style="background:var(--card-bg);border:1px solid var(--border);border-radius:3px;padding:16px;margin-bottom:20px">
    <div class="section-label">Add Server</div>
    <div class="form-group">
      <label>Name</label>
      <input id="mcp-new-name" placeholder="e.g. github">
    </div>
    <div class="form-group">
      <label>Command</label>
      <input id="mcp-new-cmd" placeholder="e.g. npx -y @modelcontextprotocol/server-github">
    </div>
    <button class="btn btn-primary btn-sm" onclick="addMCPServer()">Add Server</button>
  </div>
  <div class="section-label">GitHub Token</div>
  <div style="display:flex;gap:8px">
    <input id="gh-token" type="password" placeholder="ghp_...">
    <button class="btn btn-primary btn-sm" style="white-space:nowrap" onclick="saveGHToken()">Save Token</button>
  </div>
</div>
```

- [ ] **Step 2: Add MCP JS before `// ── Init` comment**

```javascript
// ── MCP ────────────────────────────────────────────────────────────────────
let _mcpData = { mcpServers: {} };

async function loadMCP() {
  try {
    const raw = await cockpit.file('/home/claude-code/.claude/mcp.json').read();
    _mcpData = JSON.parse(raw || '{"mcpServers":{}}');
  } catch { _mcpData = { mcpServers: {} }; }
  renderMCPTable();
  loadGHToken();
}
tabLoaders.mcp = loadMCP;

function renderMCPTable() {
  const entries = Object.entries(_mcpData.mcpServers || {});
  document.getElementById('mcp-table-body').innerHTML = entries.length
    ? entries.map(([name, cfg]) => {
        const cmdArr = [cfg.command, ...(cfg.args || [])].filter(Boolean);
        const cmd = cmdArr.join(' ');
        return `<tr>
          <td class="cyan">${name}</td>
          <td style="color:var(--muted);font-size:11px">${cmd}</td>
          <td><button class="btn btn-danger btn-sm" onclick="removeMCPServer('${name}')">Remove</button></td>
        </tr>`;
      }).join('')
    : '<tr><td colspan="3" style="color:var(--muted)">No servers configured</td></tr>';
}

async function addMCPServer() {
  const name = document.getElementById('mcp-new-name').value.trim();
  const cmdStr = document.getElementById('mcp-new-cmd').value.trim();
  if (!name || !cmdStr) { showToast('Name and command required', 'error'); return; }
  const parts = cmdStr.split(' ');
  _mcpData.mcpServers[name] = { command: parts[0], args: parts.slice(1) };
  await persistMCP();
  document.getElementById('mcp-new-name').value = '';
  document.getElementById('mcp-new-cmd').value = '';
}

async function removeMCPServer(name) {
  const ok = await confirm('Remove MCP Server', `Remove "${name}" from MCP config?`, 'Remove');
  if (!ok) return;
  delete _mcpData.mcpServers[name];
  await persistMCP();
}

async function persistMCP() {
  try {
    await cockpit.file('/home/claude-code/.claude/mcp.json').replace(JSON.stringify(_mcpData, null, 2));
    renderMCPTable();
    showToast('MCP config saved');
  } catch (err) { showToast('Error: ' + err.message, 'error'); }
}

async function loadGHToken() {
  try {
    const bashrc = await cockpit.file('/home/claude-code/.bashrc').read();
    const m = (bashrc || '').match(/export GITHUB_TOKEN="?([^"\n]+)"?/);
    if (m) document.getElementById('gh-token').value = m[1];
  } catch {}
}

async function saveGHToken() {
  const token = document.getElementById('gh-token').value.trim();
  if (!token) { showToast('Token required', 'error'); return; }
  try {
    const bashrc = await cockpit.file('/home/claude-code/.bashrc').read() || '';
    const updated = bashrc.includes('GITHUB_TOKEN')
      ? bashrc.replace(/export GITHUB_TOKEN="?[^"\n]+"?/, `export GITHUB_TOKEN="${token}"`)
      : bashrc + `\nexport GITHUB_TOKEN="${token}"\n`;
    await cockpit.file('/home/claude-code/.bashrc').replace(updated);
    showToast('GitHub token saved to ~/.bashrc');
  } catch (err) { showToast('Error: ' + err.message, 'error'); }
}
```

- [ ] **Step 3: Open in browser — verify MCP tab**

Click MCP tab. You should see:
- Table with "github" server from mock data
- "Remove" button shows confirmation modal
- "Add Server" form adds a new row and updates table
- GitHub token field pre-filled from mock bashrc

- [ ] **Step 4: Commit**

```bash
git add docs/cockpit-plugin/index.html
git commit -m "feat: Cockpit plugin — MCP tab (servers + GitHub token)"
```

---

## Task 8: Plugin — Plugins tab

**Files:**
- Modify: `docs/cockpit-plugin/index.html`

- [ ] **Step 1: Replace Plugins tab panel HTML**

```html
<div id="tab-plugins" class="tab-panel">
  <div class="section-label">Plugin State</div>
  <div id="plugin-list">
    <div style="padding:12px;color:var(--muted);font-family:var(--mono);font-size:11px">Loading...</div>
  </div>
  <div style="margin-top:12px;font-family:var(--mono);font-size:10px;color:var(--muted2)">
    Changes take effect on next <code style="background:none;border:none;color:var(--muted)">claude</code> session.
  </div>
</div>
```

- [ ] **Step 2: Add Plugins JS before `// ── Init` comment**

```javascript
// ── Plugins ────────────────────────────────────────────────────────────────
const KNOWN_PLUGINS = [
  { id: 'superpowers@claude-plugins-official',      label: 'Superpowers',      desc: 'Core workflow skills (brainstorming, TDD, review)' },
  { id: 'frontend-design@claude-plugins-official',  label: 'Frontend Design',  desc: 'UI/UX component and visual layout skills' },
  { id: 'skill-creator@claude-plugins-official',    label: 'Skill Creator',    desc: 'Build custom project-specific skills' },
];

async function loadPlugins() {
  let settings = {};
  try {
    const raw = await cockpit.file('/home/claude-code/.claude/settings.json').read();
    settings = JSON.parse(raw || '{}');
  } catch {}
  const enabled = new Set(settings.plugins?.enabled || []);
  document.getElementById('plugin-list').innerHTML = KNOWN_PLUGINS.map(p => `
    <div class="toggle">
      <div>
        <div style="font-family:var(--mono);font-size:12px">${p.label}</div>
        <div style="font-family:var(--mono);font-size:9px;color:var(--muted2);margin-top:1px">${p.id}</div>
        <div style="font-family:var(--mono);font-size:10px;color:var(--muted);margin-top:3px">${p.desc}</div>
      </div>
      <div class="toggle-switch ${enabled.has(p.id) ? 'on' : ''}"
           onclick="togglePlugin('${p.id}', this)">
        <div class="toggle-thumb"></div>
      </div>
    </div>`).join('');
}
tabLoaders.plugins = loadPlugins;

async function togglePlugin(id, el) {
  let settings = {};
  try {
    const raw = await cockpit.file('/home/claude-code/.claude/settings.json').read();
    settings = JSON.parse(raw || '{}');
  } catch {}
  if (!settings.plugins) settings.plugins = {};
  if (!Array.isArray(settings.plugins.enabled)) settings.plugins.enabled = [];
  const enabled = new Set(settings.plugins.enabled);
  if (enabled.has(id)) { enabled.delete(id); el.classList.remove('on'); }
  else                  { enabled.add(id);    el.classList.add('on');    }
  settings.plugins.enabled = [...enabled];
  try {
    await cockpit.file('/home/claude-code/.claude/settings.json').replace(JSON.stringify(settings, null, 2));
    showToast('Plugin state updated');
  } catch (err) { showToast('Error: ' + err.message, 'error'); }
}
```

- [ ] **Step 3: Open in browser — verify Plugins tab**

Click Plugins tab. You should see:
- Three plugin rows: Superpowers (on), Frontend Design (on), Skill Creator (off) — matching mock settings.json
- Clicking a toggle flips its visual state and shows success toast

- [ ] **Step 4: Commit**

```bash
git add docs/cockpit-plugin/index.html
git commit -m "feat: Cockpit plugin — Plugins tab with toggle switches"
```

---

## Task 9: Plugin — Updates tab

**Files:**
- Modify: `docs/cockpit-plugin/index.html`

- [ ] **Step 1: Replace Updates tab panel HTML**

```html
<div id="tab-updates" class="tab-panel">
  <div class="section-label">CCC Provisioner</div>
  <div class="output-box" id="ccc-update-output">Click refresh to check...</div>
  <div style="display:flex;gap:8px;margin-bottom:28px">
    <button class="btn btn-secondary btn-sm" onclick="loadCCCStatus()">↺ Refresh</button>
    <button class="btn btn-primary btn-sm" onclick="runCCCSelfUpdate()">Run ccc-self-update</button>
  </div>
  <div class="section-label">oculus-configs</div>
  <div class="output-box" id="oculus-update-output">Click "Check for Updates" to fetch status...</div>
  <div style="display:flex;gap:8px">
    <button class="btn btn-secondary btn-sm" onclick="checkOculusUpdate()">Check for Updates</button>
    <button class="btn btn-primary btn-sm" id="apply-update-btn" style="display:none" onclick="applyOculusUpdate()">Apply Update</button>
  </div>
</div>
```

- [ ] **Step 2: Add Updates JS before `// ── Init` comment**

```javascript
// ── Updates ────────────────────────────────────────────────────────────────
async function loadCCCStatus() {
  const box = document.getElementById('ccc-update-output');
  box.textContent = 'Running ccc-update-status...';
  try {
    box.textContent = await cockpit.spawn(['/usr/local/bin/ccc-update-status'], {err: 'message'});
  } catch (err) {
    box.textContent = 'Error: ' + err.message;
  }
}
tabLoaders.updates = loadCCCStatus;

async function runCCCSelfUpdate() {
  const ok = await confirm(
    'Run ccc-self-update',
    'Pull latest CCC tools from GitHub and re-apply MOTD, ccc-* scripts, and the Cockpit plugin. Continue?',
    'Update'
  );
  if (!ok) return;
  const box = document.getElementById('ccc-update-output');
  box.textContent = 'Running ccc-self-update...';
  try {
    box.textContent = await cockpit.spawn(
      ['sudo', '/usr/local/bin/ccc-self-update'],
      { err: 'message', superuser: 'try' }
    );
    showToast('ccc-self-update complete');
  } catch (err) {
    box.textContent = 'Error: ' + err.message;
    showToast('Update failed', 'error');
  }
}

async function checkOculusUpdate() {
  const box = document.getElementById('oculus-update-output');
  box.textContent = 'Fetching from origin...';
  try {
    await cockpit.spawn(['git', '-C', '/opt/oculus-configs', 'fetch', 'origin'], {err: 'message'});
    const log = await cockpit.spawn(
      ['git', '-C', '/opt/oculus-configs', 'log', 'HEAD..origin/main', '--oneline'],
      {err: 'message'}
    );
    const lines = log.trim().split('\n').filter(l => l);
    if (!lines.length) {
      box.textContent = '✓ Up to date';
      document.getElementById('apply-update-btn').style.display = 'none';
    } else {
      box.textContent = lines.length + ' commit(s) behind:\n\n' + lines.join('\n');
      document.getElementById('apply-update-btn').style.display = '';
    }
  } catch (err) { box.textContent = 'Error: ' + err.message; }
}

async function applyOculusUpdate() {
  const ok = await confirm(
    'Apply oculus-configs Update',
    'Pull latest and re-copy CLAUDE.md, rules, templates, Codex and Gemini skills. Local CLAUDE.md edits will be overwritten.',
    'Update'
  );
  if (!ok) return;
  const box = document.getElementById('oculus-update-output');
  box.textContent = 'Applying update...';
  const script = [
    'git -C /opt/oculus-configs pull',
    'cp /opt/oculus-configs/claude/CLAUDE.md /home/claude-code/.claude/CLAUDE.md',
    'cp -r /opt/oculus-configs/claude/rules/. /home/claude-code/.claude/rules/',
    'cp -r /opt/oculus-configs/templates/. /home/claude-code/Templates/',
    'mkdir -p /home/claude-code/.codex && cp /opt/oculus-configs/codex/skills/AGENTS.md /home/claude-code/.codex/AGENTS.md 2>/dev/null || true',
    'mkdir -p /home/claude-code/.gemini && cp /opt/oculus-configs/gemini/skills/GEMINI.md /home/claude-code/.gemini/GEMINI.md 2>/dev/null || true',
  ].join(' && ');
  try {
    const out = await cockpit.spawn(['bash', '-c', script], {err: 'message'});
    box.textContent = 'Done.' + (out ? '\n' + out : '');
    document.getElementById('apply-update-btn').style.display = 'none';
    showToast('oculus-configs updated');
  } catch (err) {
    box.textContent = 'Error: ' + err.message;
    showToast('Update failed', 'error');
  }
}
```

- [ ] **Step 3: Open in browser — verify Updates tab**

Click Updates tab. You should see:
- CCC output box shows "Click refresh to check..." then loads mock ccc-update-status on click
- "Check for Updates" populates the oculus-configs box with 2 pending commits from mock
- "Apply Update" button appears, confirmation modal fires on click

- [ ] **Step 4: Commit**

```bash
git add docs/cockpit-plugin/index.html
git commit -m "feat: Cockpit plugin — Updates tab (CCC + oculus-configs)"
```

---

## Task 10: Embed plugin into bash script (step 27 Cockpit block)

**Files:**
- Modify: `docs/cockpit-plugin/index.html` — swap mock script src for real cockpit.js
- Modify: `claude-code-commander.sh` — add plugin block inside step 27

- [ ] **Step 1: Swap mock script tag in index.html**

In `docs/cockpit-plugin/index.html`, replace:

```html
  <!-- Dev: swap for /cockpit/base1/cockpit.js when embedding in bash script -->
  <script src="mock-cockpit.js"></script>
```

with:

```html
  <script src="/cockpit/base1/cockpit.js"></script>
```

- [ ] **Step 2: Verify the full plugin HTML has no bare `COCKPITUI` on its own line**

```bash
grep -n '^COCKPITUI$' docs/cockpit-plugin/index.html
# Expected: no output (terminator collision would break the heredoc)
grep -n '^MANIFEST$' docs/cockpit-plugin/index.html
# Expected: no output
```

- [ ] **Step 3: Locate insertion point in bash script**

```bash
grep -n 'systemctl enable --now cockpit.socket\|CCC_UPDATEABLE_END' claude-code-commander.sh
```

Note the line number of `systemctl enable --now cockpit.socket`. The plugin block goes immediately after it.

- [ ] **Step 4: Insert manifest.json and index.html heredocs after cockpit.socket line**

After the line `systemctl enable --now cockpit.socket`, insert:

```bash
# CCC Cockpit plugin — Prism-dark management UI
mkdir -p /usr/share/cockpit/ccc
cat > /usr/share/cockpit/ccc/manifest.json << 'MANIFEST'
{
  "version": 0,
  "name": "ccc",
  "priority": 1,
  "menu": {
    "index": {
      "label": "Claude Code Commander",
      "order": 0
    }
  }
}
MANIFEST
cat > /usr/share/cockpit/ccc/index.html << 'COCKPITUI'
```
Then paste the **complete contents** of `docs/cockpit-plugin/index.html`, then close with:
```bash
COCKPITUI
```

> **Tip:** Use your editor's "insert file" feature, or: `sed -i '/systemctl enable --now cockpit.socket/r docs/cockpit-plugin/index.html' claude-code-commander.sh` (then manually add the heredoc open/close lines around the inserted content).

- [ ] **Step 5: Syntax check and verify plugin block**

```bash
bash -n claude-code-commander.sh && echo "syntax OK"
grep -n 'COCKPITUI\|manifest.json\|usr/share/cockpit/ccc' claude-code-commander.sh
# Expected: COCKPITUI open + close visible, manifest.json write visible
```

- [ ] **Step 6: Commit both files**

```bash
git add claude-code-commander.sh docs/cockpit-plugin/index.html
git commit -m "feat: embed Prism CCC Cockpit plugin into provisioner (step 27)"
```

---

## Task 11: Final validation

**Files:**
- Read: `claude-code-commander.sh`

- [ ] **Step 1: Syntax check**

```bash
bash -n claude-code-commander.sh && echo "syntax OK"
```

Expected: `syntax OK` with no output before it.

- [ ] **Step 2: Step count**

```bash
grep -c '^step [0-9]' claude-code-commander.sh
```

Expected: `28` (step 18 replaced, net count unchanged).

- [ ] **Step 3: Key assertions**

```bash
# Old CLAUDE.md heredoc gone
grep -c 'Claude Code Workspace' claude-code-commander.sh
# Expected: 0

# New step 18 present
grep 'step 18' claude-code-commander.sh
# Expected: step 18 "oculus-configs"

# oculus-configs clone present
grep 'git clone.*oculus-configs' claude-code-commander.sh
# Expected: line visible

# Codex and Gemini skill copy present
grep 'AGENTS.md\|GEMINI.md' claude-code-commander.sh
# Expected: two lines visible

# Cockpit plugin block present
grep 'usr/share/cockpit/ccc' claude-code-commander.sh
# Expected: mkdir line + write lines visible

# manifest.json valid JSON (extract and validate)
awk '/cat > \/usr\/share\/cockpit\/ccc\/manifest.json/,/^MANIFEST$/' claude-code-commander.sh \
  | grep -v 'cat >\|MANIFEST' | python3 -m json.tool > /dev/null && echo "manifest JSON valid"
# Expected: manifest JSON valid

# MOTD updated
grep '9090' claude-code-commander.sh | grep echo
# Expected: "config, projects, MCP, updates" (not "system monitoring")

# CCC_UPDATEABLE_END still present and plugin is before it
grep -n 'CCC_UPDATEABLE_END\|usr/share/cockpit/ccc' claude-code-commander.sh
# Expected: cockpit/ccc line number < CCC_UPDATEABLE_END line number
```

- [ ] **Step 4: Manual test checklist (run after a full provision)**

After provisioning a fresh container:

```
[ ] /opt/oculus-configs exists and is owned by claude-code
[ ] /home/claude-code/.claude/CLAUDE.md exists and is not the old hardcoded version
[ ] /home/claude-code/.claude/rules/ contains at least one file
[ ] /home/claude-code/Templates/ exists
[ ] /home/claude-code/.codex/AGENTS.md exists
[ ] /home/claude-code/.gemini/GEMINI.md exists
[ ] Cockpit loads at https://<ip>:9090
[ ] CCC plugin appears in Cockpit nav as "Claude Code Commander"
[ ] Overview tab: all four stat cards show values (not "—")
[ ] Overview tab: code-server pill shows green dot
[ ] Projects tab: lists projects, wizard completes without errors
[ ] CLAUDE.md tab: loads content, saves without errors
[ ] MCP tab: loads mcp.json, add/remove server works
[ ] Plugins tab: toggle switches reflect settings.json state
[ ] Updates tab: ccc-update-status output visible
```

- [ ] **Step 5: Final commit**

```bash
git add -A
git status
# Verify only expected files changed
git commit -m "feat: oculus-configs integration + Prism CCC Cockpit plugin complete"
```

---

## Self-Review Notes

**Spec coverage check:**
- ✅ Step 18: oculus-configs clone + CLAUDE.md, rules, templates, Codex/Gemini skills → Task 1
- ✅ Remove inline CLAUDE.md heredoc → Task 1
- ✅ Cockpit plugin manifest.json + index.html → Tasks 3–10
- ✅ Prism dark theme tokens → Task 4 CSS
- ✅ Overview tab (stat cards, service pills, quick links) → Task 4
- ✅ Projects tab (list + wizard) → Task 5
- ✅ CLAUDE.md tab (edit + reload from oculus-configs) → Task 6
- ✅ MCP tab (servers + GitHub token) → Task 7
- ✅ Plugins tab (toggle switches) → Task 8
- ✅ Updates tab (CCC + oculus-configs) → Task 9
- ✅ Plugin inside CCC_UPDATEABLE_START/END range → Task 10 (noted in step 3)
- ✅ MOTD update → Task 2
- ✅ chown /opt/oculus-configs to claude-code → Task 1 step 2
- ✅ No port 4827, no Python service → out of scope, not referenced anywhere

**Type consistency:** `_mcpData.mcpServers` is used consistently across `loadMCP`, `renderMCPTable`, `addMCPServer`, `removeMCPServer`, and `persistMCP`. `_wiz` wizard state object used consistently across `showWizard`, `renderWizardStep`, `wizardNext`, `createProject`. `tabLoaders` dict populated in each task, consumed by `showTab`. No naming mismatches found.
