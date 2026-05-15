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
  user: () => Promise.resolve({ name: 'claude-code', home: '/home/claude-code', groups: [] }),
};
