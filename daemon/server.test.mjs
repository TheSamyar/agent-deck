import test from 'node:test';
import assert from 'node:assert/strict';
import {
  classifyEvent,
  readHook,
  slug,
  sessionId,
  resolveApproval,
  resolveStop,
  buildTiles,
  pressGuard,
  isLocalHost,
  applyTimeouts,
  cursorWorkspace,
} from './server.mjs';
import { renderTile, xmlEscape, fitLabel } from './tiles.mjs';
import { updateCodexNotify, removeCodexNotify } from '../scripts/install.mjs';

function session(partial) {
  return {
    id: partial.id,
    agentId: partial.agentId,
    shortName: (partial.agentId || 'agent').toUpperCase(),
    instanceLabel: partial.workspace || 'main',
    workspace: partial.workspace || 'main',
    accentColor: '#38bdf8',
    status: partial.status || 'IDLE',
    detail: partial.detail || 'Ready',
    tool: partial.tool || '',
    lastHookAt: partial.lastHookAt || 0,
    updatedAt: partial.updatedAt || Date.now(),
  };
}

test('prompt events are work, not an approval', () => {
  assert.equal(classifyEvent('UserPromptSubmit', {}).status, 'WORKING');
  assert.equal(classifyEvent('beforeSubmitPrompt', {}).status, 'WORKING');
  assert.equal(classifyEvent('somethingPrompt', {}).ignore, true);
  assert.equal(classifyEvent('ask', {}).ignore, true);
});

test('permission is the only waiting event, and session end removes the agent', () => {
  const waiting = classifyEvent('PermissionRequest', { tool_name: 'Bash' });
  assert.equal(waiting.status, 'WAITING');
  assert.equal(waiting.detail, 'Approve Bash?');
  assert.equal(classifyEvent('Notification', { message: 'task finished' }).ignore, true);
  assert.equal(classifyEvent('Notification', { message: 'Needs approval to run' }).status, 'WAITING');
  assert.equal(classifyEvent('SessionEnd', {}).remove, true);
  assert.equal(classifyEvent('turn-ended', {}).status, 'DONE');
  assert.equal(classifyEvent('Stop', { error: 'nope' }).status, 'ERROR');
});

test('hook payload prefers the agent cwd over the hook process cwd', () => {
  const info = readHook({
    data: { cwd: '/work/luxwebsite', tool_name: 'Read', workspace_roots: ['/ignored'] },
    env: { pwd: '$HOME/path/to/ai-agent-deck', ppid: 42, bundleId: 'com.mitchellh.ghostty' },
  });
  assert.equal(info.workspace, 'luxwebsite');
  assert.equal(info.tool, 'Read');
  assert.equal(info.pid, 42);
  assert.equal(info.bundleId, 'com.mitchellh.ghostty');
  assert.equal(sessionId('claude', info.workspace), sessionId('claude', 'LuxWebsite'));
  assert.equal(slug('ai-agent-deck'), slug('AI-Agent-Deck'));
  assert.equal(cursorWorkspace('AI Agent Deck — ai-agent-deck'), 'ai-agent-deck');
  assert.equal(cursorWorkspace('wedding-kiss-close-to-original.jpg — apt-app'), 'apt-app');
  assert.equal(cursorWorkspace('hub2.0'), 'hub2.0');
  assert.equal(sessionId('cursor', cursorWorkspace('AI Agent Deck — ai-agent-deck')), 'cursor:ai-agent-deck');
});

test('cursor workspace roots are used when cwd is absent', () => {
  const info = readHook({ data: { workspace_roots: ['/work/ai-agent-deck'] }, env: { pwd: '/tmp' } });
  assert.equal(info.workspace, 'ai-agent-deck');
  assert.equal(info.bundleId, '');
});

test('allow and deny do not fall back to some other agent', () => {
  const sessions = new Map([
    ['claude:main', session({ id: 'claude:main', agentId: 'claude', status: 'WORKING' })],
    ['codex:main', session({ id: 'codex:main', agentId: 'codex', status: 'WAITING' })],
  ]);
  assert.equal(resolveApproval(sessions, 'claude:main'), null);
  assert.equal(resolveApproval(sessions, 'codex:main').id, 'codex:main');
  assert.equal(resolveApproval(sessions, 'all').id, 'codex:main');
  assert.equal(resolveStop(sessions, 'claude:main').id, 'claude:main');
  assert.equal(resolveStop(sessions, 'cursor:agents'), null);
});

test('a single cursor does not arm stop, and a waiting claude arms allow', () => {
  const now = Date.now();
  const cursorOnly = new Map([
    ['cursor:deck', session({ id: 'cursor:deck', agentId: 'cursor', status: 'WORKING', workspace: 'deck' })],
  ]);
  const cockpit = buildTiles({ sessions: cursorOnly, selectedId: '', forceMulti: false, now });
  assert.equal(cockpit.layoutMode, 'single_agent');
  assert.equal(cockpit.tiles.find((tile) => tile.action === 'stop').enabled, false);
  assert.equal(cockpit.tiles.find((tile) => tile.action === 'approve').enabled, false);

  const waiting = new Map([
    ['claude:lux', session({ id: 'claude:lux', agentId: 'claude', status: 'WAITING', workspace: 'lux', tool: 'Bash' })],
    ['cursor:deck', session({ id: 'cursor:deck', agentId: 'cursor', status: 'WORKING', workspace: 'deck' })],
  ]);
  const grid = buildTiles({ sessions: waiting, selectedId: '', forceMulti: false, now });
  assert.equal(grid.layoutMode, 'multi_instance');
  assert.equal(grid.tiles.find((tile) => tile.key === 'approve').target, 'claude:lux');
  assert.equal(grid.tiles.find((tile) => tile.key === 'approve').enabled, true);
  assert.equal(grid.tiles.find((tile) => tile.key === 'antigravity').status, 'OFF');
});

test('working cursor sessions go idle after ten minutes, done sessions after fifteen', () => {
  const now = Date.now();
  const sessions = new Map([
    ['cursor:deck', session({ id: 'cursor:deck', agentId: 'cursor', status: 'WORKING', updatedAt: now - 11 * 60 * 1000 })],
    ['claude:lux', session({ id: 'claude:lux', agentId: 'claude', status: 'DONE', updatedAt: now - 16 * 60 * 1000 })],
  ]);
  applyTimeouts(sessions, now);
  assert.equal(sessions.get('cursor:deck').status, 'IDLE');
  assert.equal(sessions.get('claude:lux').status, 'IDLE');
});

test('presses during a layout change and double taps are dropped', () => {
  assert.equal(pressGuard({ now: 1000, layoutChangedAt: 500, lastPress: null, key: 'codex' }), 'layout');
  assert.equal(pressGuard({ now: 2000, layoutChangedAt: 500, lastPress: { key: 'codex', at: 1800 }, key: 'codex' }), 'debounce');
  assert.equal(pressGuard({ now: 2000, layoutChangedAt: 500, lastPress: { key: 'codex', at: 1600 }, key: 'approve' }), '');
});

test('tile text is escaped and long names shrink instead of being sliced raw', () => {
  assert.equal(xmlEscape(`a&b<c>"'`), 'a&amp;b&lt;c&gt;&quot;&apos;');
  const long = fitLabel('antigravity-website-repo', 12, 12);
  assert.ok(long.text.endsWith('…'));
  assert.ok(long.size < 12);
  const svg = renderTile({
    type: 'instance',
    key: 'claude',
    agent: 'CLAUDE',
    workspace: 'a&b<c>',
    detail: 'Ready',
    status: 'IDLE',
    color: '#f97316',
    enabled: true,
  }, 0);
  assert.match(svg, /a&amp;b&lt;c&gt;/);
  assert.doesNotMatch(svg, /a&b<c>/);
  assert.match(svg, /viewBox="0 0 100 100"/);
  assert.match(svg, /\{\{size\}\}/);
});

test('summary and grid tiles have their own artwork', () => {
  const summary = renderTile({ type: 'summary', key: 'summary', count: 3, detail: '1 waiting', status: 'WAITING' }, 1);
  assert.match(summary, />AGENTS</);
  assert.match(summary, />3</);
  assert.doesNotMatch(summary, /AGENTS:/);
  const grid = renderTile({ type: 'grid', key: 'summary', detail: 'All agents' }, 0);
  assert.match(grid, />GRID</);
  const dimmed = renderTile({ type: 'action', key: 'approve', action: 'approve', label: 'ALLOW', detail: 'Ready', enabled: false }, 0);
  assert.match(dimmed, /opacity="0.38"/);
  const folder = renderTile({ type: 'repo', key: 'cursor', detail: 'luxwebsite' }, 0);
  assert.doesNotMatch(folder, /📁/);
  assert.match(folder, /<path/);
});

test('localhost is the only accepted host', () => {
  assert.equal(isLocalHost('127.0.0.1:19420'), true);
  assert.equal(isLocalHost('localhost:19420'), true);
  assert.equal(isLocalHost('evil.com'), false);
  assert.equal(isLocalHost('127.0.0.1.evil.com'), false);
});

test('codex notify updates the previous-notify target and can be removed', () => {
  const owned = 'notify = ["/Applications/Codex Computer Use.app/Sky", "turn-ended", "--previous-notify", "[\\"\\\\/old\\\\/codex-notify.sh\\",\\"turn-ended\\"]"]\nmodel = "gpt"\n';
  const updated = updateCodexNotify(owned, '/opt/homebrew/bin/node', '/repo/bin/agent-hook.mjs');
  assert.equal(updated.reason, 'previous-notify');
  assert.match(updated.toml, /agent-hook\.mjs/);
  assert.match(updated.toml, /Sky/);
  assert.match(updated.toml, /model = "gpt"/);
  const removed = removeCodexNotify(updated.toml);
  assert.equal(removed.changed, true);
  assert.doesNotMatch(removed.toml, /previous-notify/);
  assert.match(removed.toml, /Sky/);

  const other = 'notify = ["/usr/bin/say", "done"]\n';
  assert.equal(updateCodexNotify(other, '/usr/bin/node', '/repo/bin/agent-hook.mjs').changed, false);
});
