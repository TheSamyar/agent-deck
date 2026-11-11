const vscode = require('vscode');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const run = promisify(execFile);
const instanceId = crypto.randomUUID();
const terminals = new Map();
let timer, polling = false, lastResult, output, stopped = false;
const seen = new Set();
async function processTable() {
  const { stdout } = await run('/bin/ps', ['-axo', 'pid=,ppid='], { timeout: 1000, maxBuffer: 1024 * 1024 });
  return stdout.trim().split('\n').map(line => line.trim().split(/\s+/).map(Number));
}
function descendants(root, table) {
  const found = new Set([root]);
  let changed = true;
  while (changed) { changed = false; for (const [pid, parent] of table) if (found.has(parent) && !found.has(pid)) { found.add(pid); changed = true; } }
  return [...found];
}
function post(body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const request = http.request({ socketPath: path.join(process.env.AGENT_DECK_RUNTIME || path.join(os.homedir(), 'Library/Caches/AgentDeck'), 'deck.sock'), path: '/bridge', method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) }, timeout: 1500 }, response => {
      let raw = ''; response.on('data', chunk => { raw += chunk; if (raw.length > 524288) response.destroy(); }); response.on('end', () => { try { resolve(JSON.parse(raw)); } catch (error) { reject(error); } });
    });
    request.on('error', reject); request.on('timeout', () => request.destroy(new Error('Deck connection timed out'))); request.end(data);
  });
}
async function poll() {
  if (polling || stopped || !vscode.workspace.isTrusted) return;
  polling = true;
  try {
    const table = await processTable();
    const live = [];
    for (const terminal of vscode.window.terminals) {
      let id = terminals.get(terminal);
      if (!id) { id = crypto.randomUUID(); terminals.set(terminal, id); }
      const pid = await terminal.processId;
      if (pid) live.push({ id, shellPid: pid, processTree: descendants(pid, table) });
    }
    for (const terminal of terminals.keys()) if (!vscode.window.terminals.includes(terminal)) terminals.delete(terminal);
    const response = await post({ instanceId, hostPid: process.pid, workspaceFolders: vscode.workspace.workspaceFolders?.map(f => f.uri.fsPath) || [], terminals: live, result: lastResult });
    lastResult = undefined;
    const command = response.command;
    if (command?.id && !seen.has(command.id)) {
      seen.add(command.id); if (seen.size > 1000) seen.delete(seen.values().next().value);
      const terminal = [...terminals].find(([, id]) => id === command.terminalId)?.[0];
      if (!terminal || !['focus', 'stop'].includes(command.action)) throw new Error('The requested terminal is no longer open');
      terminal.show(false);
      if (command.action === 'stop') terminal.sendText('\x03', false);
      lastResult = { id: command.id, ok: true, message: command.action === 'stop' ? 'Interrupt sent to the identified terminal' : 'Revealed the identified terminal' };
      setTimeout(poll, 0);
    }
  } catch (error) {
    // Disconnection does not stop or modify terminal sessions.
    if (error.code !== 'ENOENT' && error.code !== 'ECONNREFUSED') output?.appendLine(error.message);
  } finally { polling = false; }
}
exports.activate = context => {
  output = vscode.window.createOutputChannel('Agent Deck'); context.subscriptions.push(output);
  context.environmentVariableCollection.replace('AGENT_DECK_HOST_INSTANCE', instanceId);
  context.subscriptions.push(vscode.commands.registerCommand('agentDeck.reconnect', () => poll()));
  context.subscriptions.push(vscode.window.onDidOpenTerminal(() => poll()));
  context.subscriptions.push(vscode.window.onDidCloseTerminal(() => poll()));
  timer = setInterval(poll, 1000); poll();
};
exports.deactivate = () => { stopped = true; clearInterval(timer); };
