#!/usr/bin/env node
'use strict';
const http  = require('http');
const fs    = require('fs');
const path  = require('path');
const cp    = require('child_process');
const os    = require('os');

const PORT   = parseInt(process.env.PORT || '9090');
const PUBLIC = path.join(__dirname, 'public');
const MIME   = { '.html':'text/html', '.js':'application/javascript', '.css':'text/css', '.json':'application/json' };

// ── Config ────────────────────────────────────────────────────────────────────
function readConfig() {
  try {
    return Object.fromEntries(
      fs.readFileSync('/etc/ccc/config','utf8').trim().split('\n')
        .map(l => l.match(/^(\w+)="([^"]*)"$/)).filter(Boolean).map(m => [m[1], m[2]])
    );
  } catch { return {}; }
}
const cfg      = readConfig();
const CCC_USER = cfg.CCC_USER || 'claude-code';
const HOME     = `/home/${CCC_USER}`;
const TOKEN    = (() => {
  const f = '/etc/ccc/dashboard-token';
  if (fs.existsSync(f)) return fs.readFileSync(f,'utf8').trim();
  const t = Math.random().toString(36).slice(2,10);
  try { fs.mkdirSync('/etc/ccc',{recursive:true}); fs.writeFileSync(f,t,'utf8'); } catch {}
  return t;
})();

// ── Auth ──────────────────────────────────────────────────────────────────────
function authed(req) {
  const h = req.headers.authorization || '';
  const t = h.replace(/^Bearer\s*/i,'') || new URL(req.url,'http://x').searchParams.get('token') || '';
  return t === TOKEN;
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function json(res, data, status=200) {
  const b = JSON.stringify(data);
  res.writeHead(status,{'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)});
  res.end(b);
}
function body(req) {
  return new Promise(r=>{ let b=''; req.on('data',c=>b+=c); req.on('end',()=>r(b)); });
}
function shell(cmd, opts={}) {
  return cp.execSync(cmd,{encoding:'utf8',timeout:20000,...opts}).trim();
}
function getIP() {
  for (const [,ifaces] of Object.entries(os.networkInterfaces()))
    for (const i of ifaces)
      if (!i.internal && i.family==='IPv4') return i.address;
  return 'localhost';
}

// ── File browser path guard ───────────────────────────────────────────────────
const FILE_ROOTS = [HOME, '/opt/ccc-dashboard', '/etc/ccc', '/var/log', '/tmp'];
function safePath(p) {
  if (!p) return HOME;
  const resolved = path.resolve(p);
  if (FILE_ROOTS.some(r => resolved === r || resolved.startsWith(r+'/'))) return resolved;
  return null;
}

// ── API routes ────────────────────────────────────────────────────────────────
const ROUTES = {};
const R = (m,p,fn) => ROUTES[`${m} ${p}`] = fn;

R('GET','/api/status',(req,res)=>{
  const claudeActive = (()=>{ try{ return shell(`systemctl is-active code-server@${CCC_USER} 2>/dev/null`); }catch{ return 'inactive'; } })();
  json(res,{
    user: CCC_USER, hostname: os.hostname(), ip: getIP(),
    claude:    fs.existsSync('/usr/local/bin/claude'),
    claudeMd:  fs.existsSync(`${HOME}/.claude/CLAUDE.md`),
    codeServer: claudeActive,
    uptime: Math.floor(os.uptime()),
    loadavg: os.loadavg().map(n=>n.toFixed(2)),
    mem: { total: os.totalmem(), free: os.freemem() },
  });
});

R('GET','/api/system',(req,res)=>{
  try {
    const disk = shell("df -h --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n +2")
      .split('\n').filter(l => l && !l.includes('tmpfs') && !l.includes('udev') && !l.match(/^overlay/))
      .map(l => { const p=l.trim().split(/\s+/); return {src:p[0],size:p[1],used:p[2],avail:p[3],pct:p[4],mount:p[5]}; });

    const procs = shell("ps aux --sort=-%cpu --no-headers 2>/dev/null | head -15")
      .split('\n').filter(Boolean)
      .map(l => {
        const p = l.trim().split(/\s+/);
        return { user:p[0], pid:p[1], cpu:p[2], mem:p[3], cmd:p.slice(10).join(' ').replace(/^-/,'').slice(0,40) };
      });

    const netRaw = fs.readFileSync('/proc/net/dev','utf8').trim().split('\n').slice(2)
      .map(l => { const p=l.trim().split(/\s+/); return { iface:p[0].replace(':',''), rx:parseInt(p[1]), tx:parseInt(p[9]) }; })
      .filter(n => n.iface !== 'lo');

    json(res,{
      loadavg: os.loadavg().map(n=>n.toFixed(2)),
      uptime:  os.uptime(),
      mem:     { total: os.totalmem(), free: os.freemem() },
      disk, procs, net: netRaw,
    });
  } catch(e){ json(res,{error:e.message},500); }
});

R('GET','/api/claude-md',(req,res)=>{
  const f=`${HOME}/.claude/CLAUDE.md`;
  json(res,{content: fs.existsSync(f) ? fs.readFileSync(f,'utf8') : ''});
});
R('POST','/api/claude-md',async(req,res)=>{
  try {
    const {content} = JSON.parse(await body(req));
    fs.mkdirSync(`${HOME}/.claude`,{recursive:true});
    fs.writeFileSync(`${HOME}/.claude/CLAUDE.md`, content, {mode:0o644});
    shell(`chown ${CCC_USER}:${CCC_USER} ${HOME}/.claude/CLAUDE.md`);
    json(res,{ok:true});
  } catch(e){ json(res,{error:e.message},500); }
});

R('GET','/api/mcp',(req,res)=>{
  const f=`${HOME}/.claude/mcp.json`;
  json(res, fs.existsSync(f) ? JSON.parse(fs.readFileSync(f,'utf8')) : {mcpServers:{}});
});
R('POST','/api/mcp',async(req,res)=>{
  try {
    const data = JSON.parse(await body(req));
    fs.mkdirSync(`${HOME}/.claude`,{recursive:true});
    fs.writeFileSync(`${HOME}/.claude/mcp.json`, JSON.stringify(data,null,2));
    shell(`chown ${CCC_USER}:${CCC_USER} ${HOME}/.claude/mcp.json`);
    json(res,{ok:true});
  } catch(e){ json(res,{error:e.message},500); }
});

R('GET','/api/projects',(req,res)=>{
  const dir=`${HOME}/projects`;
  try {
    const items = fs.readdirSync(dir).filter(f=>fs.statSync(path.join(dir,f)).isDirectory());
    json(res,{projects:items});
  } catch { json(res,{projects:[]}); }
});
R('POST','/api/projects',async(req,res)=>{
  try {
    const {name,location} = JSON.parse(await body(req));
    if (!name || /[\/\.]/.test(name)) { json(res,{error:'Invalid name'},400); return; }
    const loc = location || `${HOME}/projects/${name}`;
    shell(`mkdir -p "${loc}" && git -C "${loc}" init && chown -R ${CCC_USER}:${CCC_USER} "${loc}"`);
    json(res,{ok:true,location:loc});
  } catch(e){ json(res,{error:e.message},500); }
});

// ── File browser ──────────────────────────────────────────────────────────────
R('GET','/api/files',(req,res)=>{
  const p = safePath(new URL(req.url,'http://x').searchParams.get('path'));
  if (!p) { json(res,{error:'Access denied'},403); return; }
  try {
    const entries = fs.readdirSync(p,{withFileTypes:true}).map(e=>{
      const full = path.join(p,e.name);
      let size=0, mtime=0, isDir=false;
      try { const s=fs.statSync(full); size=s.size; mtime=s.mtimeMs; isDir=s.isDirectory(); } catch {}
      return { name:e.name, dir:isDir, size, mtime };
    }).sort((a,b)=> b.dir-a.dir || a.name.localeCompare(b.name));
    json(res,{path:p,parent:path.dirname(p),entries,home:HOME});
  } catch(e){ json(res,{error:e.message},500); }
});

R('GET','/api/file',(req,res)=>{
  const p = safePath(new URL(req.url,'http://x').searchParams.get('path'));
  if (!p) { json(res,{error:'Access denied'},403); return; }
  try {
    const stat = fs.statSync(p);
    if (stat.size > 512*1024) { json(res,{error:'File too large to preview (>512KB)'}); return; }
    const buf = fs.readFileSync(p);
    // Detect binary by checking for null bytes in first 8KB
    const sample = buf.slice(0,8192);
    const binary = sample.includes(0);
    json(res,{ content: binary ? null : buf.toString('utf8'), binary, size: stat.size });
  } catch(e){ json(res,{error:e.message},500); }
});

R('POST','/api/file',async(req,res)=>{
  try {
    const {path:p, content} = JSON.parse(await body(req));
    const safe = safePath(p);
    if (!safe) { json(res,{error:'Access denied'},403); return; }
    fs.mkdirSync(path.dirname(safe),{recursive:true});
    fs.writeFileSync(safe, content, 'utf8');
    json(res,{ok:true});
  } catch(e){ json(res,{error:e.message},500); }
});

R('DELETE','/api/file',async(req,res)=>{
  try {
    const p = safePath(new URL(req.url,'http://x').searchParams.get('path'));
    if (!p) { json(res,{error:'Access denied'},403); return; }
    const stat = fs.statSync(p);
    if (stat.isDirectory()) shell(`rm -rf "${p}"`);
    else fs.unlinkSync(p);
    json(res,{ok:true});
  } catch(e){ json(res,{error:e.message},500); }
});

R('POST','/api/mkdir',async(req,res)=>{
  try {
    const {path:p} = JSON.parse(await body(req));
    const safe = safePath(p);
    if (!safe) { json(res,{error:'Access denied'},403); return; }
    fs.mkdirSync(safe,{recursive:true});
    json(res,{ok:true});
  } catch(e){ json(res,{error:e.message},500); }
});

R('GET','/api/update-status',(req,res)=>{
  try { json(res,{output: shell('/usr/local/bin/ccc-update-status 2>&1')}); }
  catch(e){ json(res,{output: String(e.stdout||e.message)}); }
});
R('POST','/api/self-update',(req,res)=>{
  res.writeHead(200,{'Content-Type':'text/plain','Transfer-Encoding':'chunked'});
  const p = cp.spawn('sudo',['/usr/local/bin/ccc-self-update'],{env:process.env});
  p.stdout.on('data',d=>res.write(d));
  p.stderr.on('data',d=>res.write(d));
  p.on('close',()=>res.end());
});

R('GET','/api/settings',(req,res)=>{
  const f=`${HOME}/.claude/settings.json`;
  json(res, fs.existsSync(f) ? JSON.parse(fs.readFileSync(f,'utf8')) : {});
});
R('POST','/api/settings',async(req,res)=>{
  try {
    const data = JSON.parse(await body(req));
    fs.mkdirSync(`${HOME}/.claude`,{recursive:true});
    fs.writeFileSync(`${HOME}/.claude/settings.json`, JSON.stringify(data,null,2));
    shell(`chown ${CCC_USER}:${CCC_USER} ${HOME}/.claude/settings.json`);
    json(res,{ok:true});
  } catch(e){ json(res,{error:e.message},500); }
});

// ── HTTP server ───────────────────────────────────────────────────────────────
const server = http.createServer((req,res)=>{
  res.setHeader('Access-Control-Allow-Origin','*');
  const url = req.url.split('?')[0];

  if (url.startsWith('/api/')) {
    if (!authed(req)) { json(res,{error:'Unauthorized',token_hint:'Pass Bearer token'},401); return; }
    const handler = ROUTES[`${req.method} ${url}`];
    if (handler) { handler(req,res); return; }
    json(res,{error:'Not found'},404);
    return;
  }

  const file = url==='/' ? path.join(PUBLIC,'index.html') : path.join(PUBLIC,url);
  if (!file.startsWith(PUBLIC)) { res.writeHead(403); res.end(); return; }
  fs.readFile(file,(err,data)=>{
    if (err) {
      fs.readFile(path.join(PUBLIC,'index.html'),(_,d)=>{
        res.writeHead(d?200:404,{'Content-Type':'text/html'}); res.end(d||'Not found');
      }); return;
    }
    res.writeHead(200,{'Content-Type':MIME[path.extname(file)]||'text/plain'});
    res.end(data);
  });
});

// ── WebSocket PTY terminal ────────────────────────────────────────────────────
let pty;
try { pty = require('node-pty'); } catch { console.warn('[ccc] node-pty not found — terminal tab disabled'); }

let WebSocketServer;
try { WebSocketServer = require('ws').WebSocketServer; } catch { console.error('[ccc] ws not found'); process.exit(1); }

const wss = new WebSocketServer({server, path:'/ws/terminal'});
wss.on('connection',(ws,req)=>{
  const token = new URL(req.url,'http://x').searchParams.get('token');
  if (token !== TOKEN) { ws.close(4001,'Unauthorized'); return; }
  if (!pty) { ws.send(JSON.stringify({type:'output',data:'\r\nTerminal unavailable (node-pty not installed).\r\n'})); ws.close(); return; }

  const term = pty.spawn('/bin/bash',[],{
    name:'xterm-256color', cols:80, rows:24,
    cwd: HOME,
    env:{
      ...process.env, HOME, USER:CCC_USER, LOGNAME:CCC_USER,
      TERM:'xterm-256color',
      PATH:`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/${CCC_USER}/.local/bin:/home/${CCC_USER}/.cargo/bin`,
    },
  });

  if (process.getuid && process.getuid()===0) {
    term.write(`sudo -u ${CCC_USER} -i\n`);
  }

  ws.on('message',raw=>{
    try {
      const msg = JSON.parse(raw);
      if (msg.type==='input')  term.write(msg.data);
      if (msg.type==='resize') term.resize(msg.cols, msg.rows);
    } catch {}
  });
  term.onData(d=>{ if(ws.readyState===1) ws.send(JSON.stringify({type:'output',data:d})); });
  ws.on('close',()=>{ try{term.kill();}catch{} });
  term.onExit(()=>{ try{ws.close();}catch{} });
});

server.listen(PORT,'0.0.0.0',()=>{
  console.log(`[ccc] Dashboard: http://0.0.0.0:${PORT}  token: ${TOKEN}`);
});
