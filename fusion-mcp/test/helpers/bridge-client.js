'use strict';

// Runs the real bridge (server/index.js) as a child process and talks MCP to it over stdio,
// the way Claude Desktop does.

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');

const ENTRY = path.join(__dirname, '..', '..', 'bridge', 'server', 'index.js');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'fusion-bridge-test-'));
}

class BridgeClient {
  constructor(env = {}) {
    this.dir = env.FUSION_BRIDGE_STATE_DIR || tempDir();
    this.messages = [];
    this.waiters = [];
    this.nextId = 1;
    this.stderr = '';
    this.child = spawn(process.execPath, [ENTRY], {
      env: {
        ...process.env,
        FUSION_BRIDGE_STATE_DIR: this.dir,
        FUSION_BRIDGE_LOG_FILE: path.join(this.dir, 'bridge.log'),
        FUSION_ESSENTIALS_SETTINGS: path.join(this.dir, 'no-settings.json'),
        FUSION_AUTO_LAUNCH: 'false',
        FUSION_CONNECT_WAIT_SECONDS: '2',
        FUSION_LIST_WAIT_SECONDS: '0.5',
        FUSION_PROBE_TIMEOUT_SECONDS: '1',
        FUSION_REQUEST_TIMEOUT_SECONDS: '5',
        FUSION_BRIDGE_POLL_SECONDS: '0.2',
        ...env,
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.exited = new Promise((resolve) => this.child.on('exit', (code) => resolve(code)));
    this.child.stderr.on('data', (chunk) => { this.stderr += chunk; });
    readline.createInterface({ input: this.child.stdout }).on('line', (line) => {
      const message = JSON.parse(line); // anything but JSON on stdout is a bug
      this.messages.push(message);
      this.waiters = this.waiters.filter((waiter) => {
        if (!waiter.match(message)) return true;
        waiter.resolve(message);
        return false;
      });
    });
  }

  write(message) {
    this.child.stdin.write(`${typeof message === 'string' ? message : JSON.stringify(message)}\n`);
  }

  waitFor(match, timeoutMs = 10000, label = 'message') {
    const found = this.messages.find(match);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      const waiter = { match, resolve };
      this.waiters.push(waiter);
      setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        reject(new Error(`timed out waiting for ${label}\n--- bridge stderr ---\n${this.stderr}`));
      }, timeoutMs);
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    this.write({ jsonrpc: '2.0', id, method, params });
    return id;
  }

  request(method, params = {}, timeoutMs = 10000) {
    const id = this.send(method, params);
    return this.waitFor((m) => m.id === id && !('method' in m), timeoutMs, `reply to ${method}`);
  }

  notify(method, params = {}) {
    this.write({ jsonrpc: '2.0', method, params });
  }

  async initialize() {
    const reply = await this.request('initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'test-client', version: '1.0.0' },
    });
    this.notify('notifications/initialized');
    return reply;
  }

  async callTool(name, args = {}, timeoutMs = 10000) {
    return this.request('tools/call', { name, arguments: args }, timeoutMs);
  }

  async close() {
    this.child.stdin.end();
    return this.exited;
  }
}

module.exports = { BridgeClient, tempDir };
