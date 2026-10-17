'use strict';

// The bridge against the real Fusion-Essentials MCP transport (its server/mcp_server.py, run
// outside Fusion by helpers/fusion_essentials_server.py). Needs a checkout of Fusion-Essentials
// and a Python with pytest (its test harness imports it):
//
//   FUSION_ESSENTIALS_DIR=../Fusion-Essentials FUSION_ESSENTIALS_PYTHON=python3 node --test test/

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');
const readline = require('node:readline');
const { test } = require('node:test');

const { BridgeClient } = require('./helpers/bridge-client');
const { freePort } = require('./helpers/mock-fusion');

const repo = process.env.FUSION_ESSENTIALS_DIR;
const python = process.env.FUSION_ESSENTIALS_PYTHON || 'python3';
const skip = repo ? false : 'set FUSION_ESSENTIALS_DIR to a Fusion-Essentials checkout';

const text = (reply) => reply.result.content.map((part) => part.text).join('\n');

function startAddIn(port) {
  const child = spawn(python, [path.join(__dirname, 'helpers', 'fusion_essentials_server.py'), repo, String(port)], {
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const lines = [];
  let waiting = null;
  readline.createInterface({ input: child.stdout }).on('line', (line) => {
    lines.push(line);
    if (waiting && waiting.match(line)) {
      clearTimeout(waiting.timer);
      waiting.resolve();
      waiting = null;
    }
  });
  const next = (match) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`the Fusion-Essentials server did not report back; it printed: ${lines.join(' | ')}`)), 30000);
    waiting = { match, resolve, timer };
  });
  return {
    ready: next((line) => line.startsWith('ready')),
    command: (word) => {
      const done = next((line) => line.startsWith(word === 'stop' ? 'stopped' : 'ready'));
      child.stdin.write(`${word}\n`);
      return done;
    },
    close: () => new Promise((resolve) => {
      child.on('exit', resolve);
      child.stdin.end();
    }),
  };
}

test('works with the real Fusion-Essentials server across add-in reloads and downtime', { skip, timeout: 120000 }, async () => {
  const port = await freePort();
  const addIn = startAddIn(port);
  await addIn.ready;
  const client = new BridgeClient({ FUSION_MCP_URL: `http://127.0.0.1:${port}/mcp`, FUSION_CONNECT_WAIT_SECONDS: '15' });
  try {
    const init = await client.initialize();
    assert.equal(init.result.serverInfo.name, 'Fusion-Essentials MCP Server');
    assert.equal(init.result.protocolVersion, '2025-03-26');
    assert.match(init.result.instructions, /sys_capability_map/);

    const list = await client.request('tools/list');
    const names = list.result.tools.map((tool) => tool.name);
    assert.deepEqual(names, ['model_extrude', 'workspace_orient', 'fusion_connection_status', 'fusion_reconnect']);
    assert.equal(list.result.tools.find((tool) => tool.name === 'workspace_orient').annotations.readOnlyHint, true);

    assert.equal(text(await client.callTool('model_extrude', { distance: 2 })), 'extruded 2 cm');

    // Reloading the add-in starts a new server: the session the bridge holds now answers 404.
    await addIn.command('restart');
    assert.equal(text(await client.callTool('model_extrude', { distance: 3 })), 'extruded 3 cm');

    // The add-in stopped (Fusion closed); a call made meanwhile waits until it is back.
    await addIn.command('stop');
    const pending = client.callTool('workspace_orient', {}, 30000);
    setTimeout(() => addIn.command('restart'), 2000);
    assert.equal(text(await pending), 'Untitled design is open');

    // A tool that fails comes back as the add-in's own error result.
    const refused = await client.callTool('model_extrude', { distance: 1, colour: 'red' });
    assert.equal(refused.result.isError, true);

    const status = await client.callTool('fusion_connection_status');
    assert.match(text(status), new RegExp(`Connected to Fusion-Essentials MCP Server 0\\.2\\.0 at http://127\\.0\\.0\\.1:${port}/mcp`));
    assert.match(text(status), /"status": "healthy"/);
  } finally {
    await client.close();
    await addIn.close();
  }
});
