'use strict';

// A stand-in for the Fusion-Essentials MCP server: Streamable HTTP on 127.0.0.1, JSON answers,
// a session id per server lifetime (so a restart makes old sessions answer 404, as the add-in
// does), /health, and knobs to make it slow or go away.

const http = require('node:http');
const crypto = require('node:crypto');

function createMockFusion({ tools = defaultTools(), sse = false } = {}) {
  const state = {
    tools,
    sse,
    port: null,
    server: null,
    serverSession: null,
    calls: [],
    initializeCount: 0,
    hangToolCalls: false,
    dropNextToolCall: false,
  };

  function json(res, status, body, headers = {}) {
    const text = JSON.stringify(body);
    res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text), ...headers });
    res.end(text);
  }

  function answer(res, message, sessionId) {
    if (state.sse) {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Mcp-Session-Id': sessionId });
      res.write(`event: message\ndata: ${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/message', params: { level: 'info', data: 'working' } })}\n\n`);
      res.end(`event: message\ndata: ${JSON.stringify(message)}\n\n`);
      return;
    }
    json(res, 200, message, { 'Mcp-Session-Id': sessionId });
  }

  function handle(req, res) {
    if (req.method === 'GET' && req.url === '/health') {
      json(res, 200, { status: 'healthy', server: 'Fusion-Essentials MCP Server', version: '0.2.0', bound: { port: state.port } });
      return;
    }
    if (req.method !== 'POST' || req.url !== '/mcp') {
      json(res, 404, { error: 'not found' });
      return;
    }
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const message = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      const sessionHeader = req.headers['mcp-session-id'];
      if (message.method !== 'initialize' && sessionHeader && !sessionHeader.startsWith(state.serverSession)) {
        res.writeHead(404, { 'Content-Length': 0 });
        res.end();
        return;
      }
      if (message.method === 'initialize') {
        state.initializeCount += 1;
        const clientSession = `${state.serverSession}.${crypto.randomBytes(8).toString('hex')}`;
        answer(res, {
          jsonrpc: '2.0',
          id: message.id,
          result: {
            protocolVersion: '2025-03-26',
            capabilities: { tools: {}, resources: {} },
            serverInfo: { name: 'Fusion-Essentials MCP Server', version: '0.2.0' },
            instructions: 'Call workspace_orient first.',
          },
        }, clientSession);
        return;
      }
      if (!('id' in message)) {
        res.writeHead(202, { 'Content-Length': 0, 'Mcp-Session-Id': sessionHeader || state.serverSession });
        res.end();
        return;
      }
      if (message.method === 'tools/list') {
        answer(res, { jsonrpc: '2.0', id: message.id, result: { tools: state.tools } }, sessionHeader);
        return;
      }
      if (message.method === 'resources/list') {
        answer(res, { jsonrpc: '2.0', id: message.id, result: { resources: [{ uri: 'guide://x', name: 'x' }] } }, sessionHeader);
        return;
      }
      if (message.method === 'tools/call') {
        state.calls.push(message.params);
        if (state.dropNextToolCall) {
          state.dropNextToolCall = false;
          req.socket.destroy();
          return;
        }
        if (state.hangToolCalls) return; // never answers
        answer(res, {
          jsonrpc: '2.0',
          id: message.id,
          result: { content: [{ type: 'text', text: `ran ${message.params.name}` }], isError: false },
        }, sessionHeader);
        return;
      }
      answer(res, { jsonrpc: '2.0', id: message.id, error: { code: -32601, message: `Method not found: ${message.method}` } }, sessionHeader);
    });
  }

  return {
    state,
    get url() { return `http://127.0.0.1:${state.port}/mcp`; },
    // (Re)start on the same port, as a new server lifetime: sessions from before now answer 404.
    async start(port = state.port || 0) {
      state.serverSession = crypto.randomBytes(8).toString('hex');
      state.server = http.createServer(handle);
      await new Promise((resolve, reject) => {
        state.server.once('error', reject);
        state.server.listen(port, '127.0.0.1', resolve);
      });
      state.port = state.server.address().port;
      return state.port;
    },
    async stop() {
      if (!state.server) return;
      state.server.closeAllConnections?.();
      await new Promise((resolve) => state.server.close(resolve));
      state.server = null;
    },
  };
}

function defaultTools() {
  return [
    {
      name: 'workspace_orient',
      description: 'What is open in Fusion.',
      inputSchema: { type: 'object', properties: {} },
      annotations: { readOnlyHint: true },
    },
    {
      name: 'model_extrude',
      description: 'Extrude a profile.',
      inputSchema: { type: 'object', properties: { distance: { type: 'number' } } },
      annotations: { readOnlyHint: false },
    },
  ];
}

// A free loopback port nobody is listening on.
async function freePort() {
  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

module.exports = { createMockFusion, defaultTools, freePort };
