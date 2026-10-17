'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const { Bridge, loadConfig, readConfiguredPort } = require('../bridge/server/bridge');
const { BridgeClient, tempDir } = require('./helpers/bridge-client');
const { createMockFusion, defaultTools, freePort } = require('./helpers/mock-fusion');

const toolNames = (reply) => reply.result.tools.map((tool) => tool.name);
const text = (reply) => reply.result.content.map((part) => part.text).join('\n');

async function withBridge(env, run) {
  const client = new BridgeClient(env);
  try {
    await run(client);
  } finally {
    await client.close();
  }
}

test('forwards initialize, tools/list and tools/call to Fusion', async () => {
  const fusion = createMockFusion();
  await fusion.start();
  try {
    await withBridge({ FUSION_MCP_URL: fusion.url }, async (client) => {
      const init = await client.initialize();
      assert.equal(init.result.serverInfo.name, 'Fusion-Essentials MCP Server');
      assert.equal(init.result.protocolVersion, '2025-03-26');
      assert.equal(init.result.capabilities.tools.listChanged, true);
      assert.match(init.result.instructions, /workspace_orient/);
      assert.match(init.result.instructions, /fusion_connection_status/);

      const list = await client.request('tools/list');
      assert.deepEqual(toolNames(list), ['workspace_orient', 'model_extrude', 'fusion_connection_status', 'fusion_reconnect']);

      const call = await client.callTool('model_extrude', { distance: 5 });
      assert.equal(text(call), 'ran model_extrude');
      assert.deepEqual(fusion.state.calls, [{ name: 'model_extrude', arguments: { distance: 5 } }]);

      const resources = await client.request('resources/list');
      assert.equal(resources.result.resources.length, 1);
    });
  } finally {
    await fusion.stop();
  }
});

test('starts with Fusion closed, then picks Fusion up and tells Claude its tools changed', async () => {
  const port = await freePort();
  const fusion = createMockFusion();
  await withBridge({ FUSION_MCP_URL: `http://127.0.0.1:${port}/mcp` }, async (client) => {
    const init = await client.initialize();
    assert.ok(init.result, 'initialize must succeed without Fusion');
    assert.equal(init.result.capabilities.tools.listChanged, true);

    const before = await client.request('tools/list');
    assert.deepEqual(toolNames(before), ['fusion_connection_status', 'fusion_reconnect']);

    const empty = await client.request('resources/list');
    assert.deepEqual(empty.result, { resources: [] });

    await fusion.start(port);
    try {
      await client.waitFor((m) => m.method === 'notifications/tools/list_changed', 10000, 'tools/list_changed');
      const after = await client.request('tools/list');
      assert.deepEqual(toolNames(after), ['workspace_orient', 'model_extrude', 'fusion_connection_status', 'fusion_reconnect']);
    } finally {
      await fusion.stop();
    }
  });
});

test('remembers the tool list, so Claude sees Fusion tools while Fusion is closed', async () => {
  const fusion = createMockFusion();
  await fusion.start();
  const dir = tempDir();
  await withBridge({ FUSION_MCP_URL: fusion.url, FUSION_BRIDGE_STATE_DIR: dir }, async (client) => {
    await client.initialize();
    await client.request('tools/list');
  });
  const url = fusion.url;
  await fusion.stop();

  await withBridge({ FUSION_MCP_URL: url, FUSION_BRIDGE_STATE_DIR: dir }, async (client) => {
    const init = await client.initialize();
    assert.equal(init.result.serverInfo.name, 'Fusion-Essentials MCP Server', 'cached initialize result');
    const list = await client.request('tools/list');
    assert.deepEqual(toolNames(list), ['workspace_orient', 'model_extrude', 'fusion_connection_status', 'fusion_reconnect']);
  });
});

test('opens a new session when Fusion restarts and forgets the old one', async () => {
  const fusion = createMockFusion();
  const port = await fusion.start();
  try {
    await withBridge({ FUSION_MCP_URL: fusion.url }, async (client) => {
      await client.initialize();
      await client.request('tools/list');
      assert.equal(text(await client.callTool('model_extrude', { distance: 1 })), 'ran model_extrude');
      const sessionsBefore = fusion.state.initializeCount;

      await fusion.stop();
      await fusion.start(port); // a new server lifetime: the old session id now answers 404

      assert.equal(text(await client.callTool('model_extrude', { distance: 2 })), 'ran model_extrude');
      assert.equal(fusion.state.initializeCount, sessionsBefore + 1);
      assert.equal(fusion.state.calls.length, 2);
    });
  } finally {
    await fusion.stop();
  }
});

test('a tool call waits for Fusion to come back', async () => {
  const fusion = createMockFusion();
  const port = await fusion.start();
  try {
    await withBridge({ FUSION_MCP_URL: fusion.url, FUSION_CONNECT_WAIT_SECONDS: '10' }, async (client) => {
      await client.initialize();
      await fusion.stop();
      const pending = client.callTool('workspace_orient', {}, 15000);
      setTimeout(() => { fusion.start(port); }, 1500);
      assert.equal(text(await pending), 'ran workspace_orient');
    });
  } finally {
    await fusion.stop();
  }
});

test('explains an unreachable Fusion instead of failing, and keeps running', async () => {
  const port = await freePort();
  await withBridge({ FUSION_MCP_URL: `http://127.0.0.1:${port}/mcp`, FUSION_CONNECT_WAIT_SECONDS: '1' }, async (client) => {
    await client.initialize();
    const call = await client.callTool('model_extrude', { distance: 1 });
    assert.equal(call.result.isError, true);
    if (process.platform === 'darwin') {
      // On a Mac the bridge looks for the Fusion process, which is not running here.
      assert.match(text(call), /Autodesk Fusion is not running/);
    } else {
      assert.match(text(call), new RegExp(`Nothing answers at http://127\\.0\\.0\\.1:${port}/mcp`));
      assert.match(text(call), /Fusion-Essentials/);
    }
    assert.match(text(call), /fusion_reconnect/);

    const status = await client.callTool('fusion_connection_status');
    assert.equal(status.result.isError, false);
    assert.match(text(status), /"connected": false/);

    assert.deepEqual((await client.request('ping')).result, {});
  });
});

test('follows the port set in the Fusion-Essentials settings file', async () => {
  const fusion = createMockFusion();
  const port = await fusion.start();
  const dir = tempDir();
  const settings = path.join(dir, 'FusionEssentialsSettings.json');
  fs.writeFileSync(settings, JSON.stringify({
    'GTF_Fusion-Essentials_MCP': { name: 'MCP Server', settings: { mcp_port: { type: 'number', default: port } } },
  }));
  assert.equal(readConfiguredPort(settings), port);
  try {
    await withBridge({ FUSION_ESSENTIALS_SETTINGS: settings }, async (client) => {
      await client.initialize();
      const status = await client.callTool('fusion_connection_status');
      assert.match(text(status), new RegExp(`Connected to Fusion-Essentials MCP Server 0\\.2\\.0 at http://127\\.0\\.0\\.1:${port}/mcp`));
      assert.match(text(status), /"status": "healthy"/);
    });
  } finally {
    await fusion.stop();
  }
});

test('never sends a changing tool call twice when the connection drops mid-call', async () => {
  const fusion = createMockFusion();
  await fusion.start();
  try {
    await withBridge({ FUSION_MCP_URL: fusion.url }, async (client) => {
      await client.initialize();
      await client.request('tools/list'); // learns which tools are read-only

      fusion.state.dropNextToolCall = true;
      const write = await client.callTool('model_extrude', { distance: 1 });
      assert.equal(write.result.isError, true);
      assert.match(text(write), /connection to Fusion dropped/);
      assert.match(text(write), /may or may not have taken effect/);
      assert.equal(fusion.state.calls.length, 1, 'a write must not be repeated blindly');

      fusion.state.dropNextToolCall = true;
      const read = await client.callTool('workspace_orient');
      assert.equal(text(read), 'ran workspace_orient', 'a read-only tool is simply asked again');
      assert.equal(fusion.state.calls.length, 3);
    });
  } finally {
    await fusion.stop();
  }
});

test('gives up on a hung call after the request timeout and stays usable', async () => {
  const fusion = createMockFusion();
  await fusion.start();
  try {
    await withBridge({ FUSION_MCP_URL: fusion.url, FUSION_REQUEST_TIMEOUT_SECONDS: '1' }, async (client) => {
      await client.initialize();
      fusion.state.hangToolCalls = true;
      const hung = await client.callTool('model_extrude', { distance: 1 });
      assert.equal(hung.result.isError, true);
      assert.match(text(hung), /did not answer within 1 s/);
      fusion.state.hangToolCalls = false;
      assert.equal(text(await client.callTool('model_extrude', { distance: 1 })), 'ran model_extrude');
    });
  } finally {
    await fusion.stop();
  }
});

test('a request Claude cancels while waiting for Fusion gets no reply', async () => {
  const port = await freePort();
  await withBridge({ FUSION_MCP_URL: `http://127.0.0.1:${port}/mcp`, FUSION_CONNECT_WAIT_SECONDS: '3' }, async (client) => {
    await client.initialize();
    const id = client.send('tools/call', { name: 'model_extrude', arguments: {} });
    await new Promise((resolve) => setTimeout(resolve, 300));
    client.notify('notifications/cancelled', { requestId: id, reason: 'user stopped' });
    await new Promise((resolve) => setTimeout(resolve, 4000));
    assert.equal(client.messages.filter((m) => m.id === id).length, 0);
    assert.deepEqual((await client.request('ping')).result, {});
  });
});

test('passes on server-sent events, including notifications sent before the reply', async () => {
  const fusion = createMockFusion({ sse: true });
  await fusion.start();
  try {
    await withBridge({ FUSION_MCP_URL: fusion.url }, async (client) => {
      await client.initialize();
      assert.equal(text(await client.callTool('workspace_orient')), 'ran workspace_orient');
      assert.ok(client.messages.some((m) => m.method === 'notifications/message'));
    });
  } finally {
    await fusion.stop();
  }
});

test('fusion_reconnect refreshes the tools after the add-in reloads with different ones', async () => {
  const fusion = createMockFusion();
  const port = await fusion.start();
  try {
    await withBridge({ FUSION_MCP_URL: fusion.url }, async (client) => {
      await client.initialize();
      await client.request('tools/list');
      await fusion.stop();
      fusion.state.tools = [...defaultTools(), { name: 'cam_get', inputSchema: { type: 'object' } }];
      await fusion.start(port);

      const reply = await client.callTool('fusion_reconnect', { launch_fusion: false, wait_seconds: 5 });
      assert.equal(reply.result.isError, false);
      assert.match(text(reply), /3 Fusion tools are available\. The tool list changed/);
      await client.waitFor((m) => m.method === 'notifications/tools/list_changed', 5000, 'tools/list_changed');
      assert.ok(toolNames(await client.request('tools/list')).includes('cam_get'));
    });
  } finally {
    await fusion.stop();
  }
});

test('answers input that is not JSON with a parse error and carries on', async () => {
  await withBridge({ FUSION_MCP_URL: 'http://127.0.0.1:1/mcp' }, async (client) => {
    client.write('this is not json');
    const error = await client.waitFor((m) => m.error && m.id === null, 5000, 'parse error');
    assert.equal(error.error.code, -32700);
    assert.deepEqual((await client.request('ping')).result, {});
  });
});

// In-process: the bridge with a fake Fusion app, to check when it starts Fusion.
function inProcess(env, fusionApp) {
  const dir = tempDir();
  const config = loadConfig({
    FUSION_BRIDGE_STATE_DIR: dir,
    FUSION_ESSENTIALS_SETTINGS: path.join(dir, 'none.json'),
    FUSION_PROBE_TIMEOUT_SECONDS: '1',
    FUSION_LIST_WAIT_SECONDS: '0.3',
    FUSION_BRIDGE_POLL_SECONDS: '0',
    ...env,
  }, 'darwin', dir);
  const sent = [];
  const bridge = new Bridge({ config, send: (m) => sent.push(m), fusion: fusionApp });
  const call = (message) => new Promise((resolve, reject) => {
    const started = sent.length;
    bridge.dispatch(message);
    const giveUp = setTimeout(() => { clearInterval(timer); reject(new Error('no reply')); }, 20000);
    const timer = setInterval(() => {
      const reply = sent.slice(started).find((m) => m.id === message.id && !('method' in m));
      if (reply) {
        clearInterval(timer);
        clearTimeout(giveUp);
        resolve(reply);
      }
    }, 20);
  });
  return { bridge, sent, call };
}

test('starts Fusion once when a tool needs it, then waits for the add-in', async () => {
  const fusion = createMockFusion();
  const port = await freePort();
  const launches = [];
  let running = false;
  const app = {
    isRunning: async () => running,
    launch: async () => {
      launches.push(Date.now());
      running = true;
      setTimeout(() => { fusion.start(port); }, 1000); // Fusion takes a moment to load the add-in
      return true;
    },
  };
  const { bridge, call } = inProcess({ FUSION_MCP_URL: `http://127.0.0.1:${port}/mcp`, FUSION_CONNECT_WAIT_SECONDS: '10' }, app);
  try {
    assert.equal(bridge.config.autoLaunch, true, 'on by default on macOS');
    await call({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {} } });
    assert.equal(launches.length, 0, 'initialize must not start Fusion');
    const reply = await call({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'workspace_orient', arguments: {} } });
    assert.equal(reply.result.content[0].text, 'ran workspace_orient');
    assert.equal(launches.length, 1);
  } finally {
    bridge.close();
    await fusion.stop();
  }
});

test('says plainly when Fusion is not running and auto-launch is off', async () => {
  const port = await freePort();
  const app = { isRunning: async () => false, launch: async () => assert.fail('must not launch') };
  const { bridge, call } = inProcess({
    FUSION_MCP_URL: `http://127.0.0.1:${port}/mcp`,
    FUSION_AUTO_LAUNCH: 'false',
    FUSION_CONNECT_WAIT_SECONDS: '0.5',
  }, app);
  try {
    const reply = await call({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'model_extrude', arguments: {} } });
    assert.equal(reply.result.isError, true);
    assert.match(reply.result.content[0].text, /Autodesk Fusion is not running/);
  } finally {
    bridge.close();
  }
});

test('names the add-in when Fusion runs but its MCP server does not answer', async () => {
  const port = await freePort();
  const app = { isRunning: async () => true, launch: async () => assert.fail('must not launch') };
  const { bridge, call } = inProcess({ FUSION_MCP_URL: `http://127.0.0.1:${port}/mcp`, FUSION_CONNECT_WAIT_SECONDS: '0.5' }, app);
  try {
    const reply = await call({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'model_extrude', arguments: {} } });
    assert.match(reply.result.content[0].text, /Autodesk Fusion is running, but nothing answers/);
    assert.match(reply.result.content[0].text, /Scripts and Add-Ins, select Fusion-Essentials, click Run/);
  } finally {
    bridge.close();
  }
});
