#!/usr/bin/env node
import http from 'node:http';
import { execFileSync } from 'node:child_process';

function parentTty() {
  if (process.env.TTY) return process.env.TTY;
  try {
    const tty = execFileSync('/bin/ps', ['-p', String(process.ppid), '-o', 'tty='], { encoding: 'utf8', timeout: 300 }).trim();
    return /^ttys[0-9]+$/.test(tty) ? '/dev/' + tty : '';
  } catch { return ''; }
}

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  if (raw.length < 65536) raw += chunk;
});
process.stdin.on('end', () => {
  let data = {};
  try {
    if (raw.trim()) data = JSON.parse(raw);
  } catch {
    data = {};
  }

  const agent = process.argv[2] || 'unknown';
  const event = process.argv[3] || 'activity';
  const payload = JSON.stringify({
    agent,
    event,
    data,
    env: {
      pwd: process.env.PWD || process.cwd(),
      termProgram: process.env.TERM_PROGRAM || '',
      bundleId: process.env.__CFBundleIdentifier || '',
      tty: parentTty(),
      terminalId: process.env.ITERM_SESSION_ID?.split(':').at(-1) || process.env.TERM_SESSION_ID || '',
      ppid: process.ppid,
      timestamp: Date.now(),
    },
  });

  const req = http.request({
    hostname: '127.0.0.1',
    port: Number(process.env.AGENT_DECK_PORT || 19420),
    path: `/hook/${encodeURIComponent(agent)}/${encodeURIComponent(event)}`,
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload),
      'X-Agent-Deck': '1',
    },
    timeout: 200,
  }, (res) => {
    res.resume();
    process.exit(0);
  });
  req.on('error', () => process.exit(0));
  req.on('timeout', () => {
    req.destroy();
    process.exit(0);
  });
  req.write(payload);
  req.end();
});
