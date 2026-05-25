import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('container-code-companion/web/app.js', 'utf8');
const match = source.match(/function updateStatusBadge\(statusText, logText\) \{[\s\S]*?\n\}/);
assert.ok(match, 'updateStatusBadge function not found');

const context = {};
vm.runInNewContext(`${match[0]}; this.updateStatusBadge = updateStatusBadge;`, context);

assert.equal(
  context.updateStatusBadge(
    'Container Code Companion Update Status\n  Update available.\n',
    'Self-update successful: 2026-05-24 12:00:00 -0400',
  ),
  'Updates available',
  'fresh update-status output must override an older successful self-update log',
);

assert.equal(
  context.updateStatusBadge(
    'Container Code Companion Update Status\n  Up to date.\n',
    'Self-update successful: 2026-05-24 12:00:00 -0400',
  ),
  'Current',
  'up-to-date status should still be current',
);
