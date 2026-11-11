import test from 'node:test';
import assert from 'node:assert/strict';
import { matchWorkspace, hostFor, CURSOR_BUNDLE, layoutSignature, serialQueue, terminalScript } from './actions.mjs';
import { applyHook, publicStatus, execute, handlePress } from './server.mjs';
import { cursorWorkspace } from './logic.mjs';

test('Cursor-hosted CLI sessions route to Cursor, not a generic app opener', () => {
  assert.equal(hostFor({agentId:'claude', bundleId:CURSOR_BUNDLE}), CURSOR_BUNDLE);
  const warning = '2.1.314 — cories — The following extensions want to relaunch the terminal to contribute to its environment: - Git';
  assert.equal(cursorWorkspace(warning), 'cories');
  assert.equal(matchWorkspace([warning, 'codex — ai-agent-deck'], 'cories'), warning);
  assert.throws(() => matchWorkspace(['codex — deck-other'], 'deck'), /No open window/);
  assert.throws(() => matchWorkspace(['a — deck', 'b — deck'], 'deck'), /Multiple windows/);
});

test('layout revision changes for actions and targets but not animation or status', () => {
  const tiles = [{key:'0', action:'focus', target:'a', enabled:true}];
  assert.equal(layoutSignature(tiles), layoutSignature([{...tiles[0], status:'WORKING', svg:'new frame'}]));
  assert.notEqual(layoutSignature(tiles), layoutSignature([{...tiles[0], target:'b'}]));
});

test('action queue waits beyond polling timeout and recovers after rejection', async () => {
  const queue = serialQueue();
  const order = [];
  const first = queue(async () => { await new Promise(r => setTimeout(r, 750)); order.push(1); throw new Error('failed'); });
  const second = queue(async () => { order.push(2); return 'done'; });
  await assert.rejects(first, /failed/);
  assert.equal(await second, 'done');
  assert.deepEqual(order, [1,2]);
});

test('failed verified focus does not approve, deny, stop, or clear DONE', async () => {
  applyHook('claude', 'PermissionRequest', {data:{cwd:'/test/control',tool_name:'Bash'}});
  const calls = [];
  const fail = async (session, key) => { calls.push(key); return {ok:false,error:'Target is ambiguous'}; };
  for (const action of ['approve','deny','stop']) {
    const result = await execute(action, 'claude:control', fail);
    assert.equal(result.ok, false);
    assert.equal(publicStatus().sessions['claude:control'].status, 'WAITING');
  }
  assert.deepEqual(calls, ['return','escape','interrupt']);
  applyHook('claude','Stop',{data:{cwd:'/test/control'}});
  await execute('focus','claude:control',fail);
  assert.equal(publicStatus().sessions['claude:control'].status, 'DONE');
  await execute('focus','claude:control',async()=>({ok:true}));
  assert.equal(publicStatus().sessions['claude:control'].status, 'IDLE');
  applyHook('claude','SessionEnd',{data:{cwd:'/test/control'}});
});

test('stale layout press cannot execute the newly displayed action', async () => {
  const status = publicStatus();
  const result = await handlePress('dashboard', status.revision - 1);
  assert.equal(result.ok, false);
  assert.equal(result.ignored, 'stale');
});

test('hook keeps terminal identity and native terminal scripts verify selection before typing', () => {
  applyHook('claude','PermissionRequest',{data:{cwd:'/test/identity',session_id:'abc'},env:{tty:'/dev/ttys006',terminalId:'session-1'}});
  const session = publicStatus().sessions['claude:identity'];
  assert.equal(session.tty,'/dev/ttys006');
  assert.equal(session.agentSessionId,'abc');
  const script = terminalScript('com.apple.Terminal','','','return');
  assert.ok(script.indexOf('Terminal selection changed') < script.indexOf('key code 36'));
  applyHook('claude','SessionEnd',{data:{cwd:'/test/identity'}});
});
