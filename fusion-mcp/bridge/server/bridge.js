'use strict';

// Fusion MCP bridge: the stdio MCP server Claude Desktop (and Cowork) launches. It forwards every
// request to the Fusion-Essentials add-in's Streamable HTTP server inside Autodesk Fusion.
//
// Claude only ever talks to this process, so the connector stays up while Fusion is closed,
// starting, reloading its add-in or busy. The bridge reconnects by itself: it re-reads the add-in's
// port, starts a fresh MCP session when Fusion forgets the old one, waits for Fusion (starting it
// if asked), and answers tools/list from its cache when Fusion is not there yet.

const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');

const BRIDGE_NAME = 'fusion-mcp-bridge';
const BRIDGE_VERSION = '1.0.0';

// Fusion-Essentials' endpoint and the settings entry that can move its port.
const DEFAULT_PORT = 37182;
const MCP_PATH = '/mcp';
const SETTINGS_GROUP = 'GTF_Fusion-Essentials_MCP';
const PORT_SETTING = 'mcp_port';
const PORT_MIN = 1024;
const PORT_MAX = 49151;

// What Fusion-Essentials implements; offered when neither Fusion nor the cache can say.
const FALLBACK_PROTOCOL_VERSION = '2025-03-26';

const STATUS_TOOL = 'fusion_connection_status';
const RECONNECT_TOOL = 'fusion_reconnect';

// Requests that change nothing, so one that may or may not have reached Fusion can be sent again.
const READ_ONLY_METHODS = new Set([
  'initialize', 'ping', 'tools/list', 'resources/list', 'resources/read',
  'resources/templates/list', 'prompts/list', 'prompts/get', 'completion/complete',
]);
// Listings answered with an empty page, not an error, while Fusion is unreachable.
const LIST_RESULT_KEYS = {
  'resources/list': 'resources',
  'resources/templates/list': 'resourceTemplates',
  'prompts/list': 'prompts',
};

// The main Fusion executable, as `ps -axo comm=` prints it on macOS.
const FUSION_PROCESS = /(^|\/)Autodesk Fusion( 360)?$/;
const FUSION_APP_NAMES = ['Autodesk Fusion', 'Autodesk Fusion 360'];

const BRIDGE_INSTRUCTIONS =
  'This Fusion connection runs through a local bridge that reconnects by itself when Fusion or ' +
  `the Fusion-Essentials add-in restarts. If a Fusion tool says Fusion is unreachable, call ${STATUS_TOOL} ` +
  `to see why, or ${RECONNECT_TOOL} to connect again (it can start Fusion), instead of operating the ` +
  'screen. If Fusion needs the user (a dialog to close, the add-in to run), tell them what to do.';

const CANCELLED = Symbol('cancelled');

// ---- configuration -------------------------------------------------------------------------

function envNumber(env, name, fallback) {
  const raw = env[name];
  if (raw === undefined || String(raw).trim() === '') return fallback;
  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 ? value : fallback;
}

function envBool(env, name, fallback) {
  const raw = String(env[name] || '').trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(raw)) return true;
  if (['0', 'false', 'no', 'off'].includes(raw)) return false;
  return fallback;
}

function validPort(value) {
  return Number.isInteger(value) && value >= PORT_MIN && value <= PORT_MAX ? value : null;
}

function defaultSettingsFile(env, platform, home) {
  const file = 'FusionEssentialsSettings.json';
  if (platform === 'darwin') {
    return path.join(home, 'Library', 'Application Support', 'GTF_Fusion-Essentials', file);
  }
  if (platform === 'win32') {
    return path.join(env.APPDATA || path.join(home, 'AppData', 'Roaming'), 'GTF_Fusion-Essentials', file);
  }
  return path.join(home, '.GTF_Fusion-Essentials', file);
}

function loadConfig(env = process.env, platform = process.platform, home = os.homedir()) {
  const mac = platform === 'darwin';
  const stateDir = env.FUSION_BRIDGE_STATE_DIR ||
    (mac ? path.join(home, 'Library', 'Caches', 'Fusion MCP Bridge') : path.join(home, '.cache', 'fusion-mcp-bridge'));
  return {
    platform,
    url: String(env.FUSION_MCP_URL || '').trim() || null,
    port: validPort(Number(env.FUSION_MCP_PORT)),
    settingsFile: env.FUSION_ESSENTIALS_SETTINGS || defaultSettingsFile(env, platform, home),
    autoLaunch: envBool(env, 'FUSION_AUTO_LAUNCH', mac),
    // How long a tool call waits for Fusion to answer before it reports why it could not. Under
    // a minute, so the explanation reaches Claude before Claude's own request timeout does.
    connectWaitMs: envNumber(env, 'FUSION_CONNECT_WAIT_SECONDS', 45) * 1000,
    // How long initialize and tools/list wait before answering from the cache.
    listWaitMs: envNumber(env, 'FUSION_LIST_WAIT_SECONDS', 3) * 1000,
    requestTimeoutMs: envNumber(env, 'FUSION_REQUEST_TIMEOUT_SECONDS', 300) * 1000,
    probeTimeoutMs: envNumber(env, 'FUSION_PROBE_TIMEOUT_SECONDS', 5) * 1000,
    // While Claude holds a cached tool list, how often to look for Fusion in the background.
    pollMs: envNumber(env, 'FUSION_BRIDGE_POLL_SECONDS', 10) * 1000,
    // After starting Fusion, how long to give it before starting it again.
    launchSettleMs: envNumber(env, 'FUSION_LAUNCH_SETTLE_SECONDS', 180) * 1000,
    stateFile: path.join(stateDir, 'state.json'),
    logFile: env.FUSION_BRIDGE_LOG_FILE ||
      (mac ? path.join(home, 'Library', 'Logs', 'Fusion MCP Bridge', 'bridge.log') : path.join(stateDir, 'bridge.log')),
  };
}

// The port Fusion-Essentials is set to use, or null when its settings file does not name a valid one.
function readConfiguredPort(file) {
  try {
    const settings = JSON.parse(fs.readFileSync(file, 'utf8'));
    return validPort(settings?.[SETTINGS_GROUP]?.settings?.[PORT_SETTING]?.default);
  } catch {
    return null;
  }
}

// ---- logging and state -----------------------------------------------------------------------

const LOG_LIMIT_BYTES = 5 * 1024 * 1024;

function createLogger(file, stderr = process.stderr) {
  let directoryReady = false;
  return function log(message) {
    const line = `${new Date().toISOString()} ${message}\n`;
    try { stderr.write(line); } catch { /* stderr gone: the file still gets it */ }
    if (!file) return;
    try {
      if (!directoryReady) {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        directoryReady = true;
      }
      try {
        if (fs.statSync(file).size > LOG_LIMIT_BYTES) fs.renameSync(file, `${file}.1`);
      } catch { /* no log yet */ }
      fs.appendFileSync(file, line);
    } catch { /* logging must never take the bridge down */ }
  };
}

function loadState(file) {
  try {
    const state = JSON.parse(fs.readFileSync(file, 'utf8'));
    return state && typeof state === 'object' && !Array.isArray(state) ? state : {};
  } catch {
    return {};
  }
}

function writeStateFile(file, state) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(state));
  fs.renameSync(temp, file);
}

function fingerprint(value) {
  return crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---- HTTP transport --------------------------------------------------------------------------

// kind: 'unreachable' (nothing listening), 'interrupted' (connection dropped), 'timeout',
// 'http' (an error status) or 'protocol' (an answer that is not MCP). `delivered` is false only
// when the request certainly never reached Fusion, which makes any request safe to send again.
class TransportError extends Error {
  constructor(kind, message, { delivered = true, code = null, status = null } = {}) {
    super(message);
    this.kind = kind;
    this.delivered = delivered;
    this.code = code;
    this.status = status;
  }
}

class UnreachableError extends Error {}

const UNREACHABLE_CODES = new Set(['ECONNREFUSED', 'ENOTFOUND', 'EADDRNOTAVAIL', 'EHOSTUNREACH', 'ENETUNREACH']);

function classifySocketError(err, delivered) {
  const code = err.code || null;
  if (!delivered) {
    const kind = UNREACHABLE_CODES.has(code) ? 'unreachable' : 'interrupted';
    return new TransportError(kind, `nothing answered (${code || err.message})`, { delivered: false, code });
  }
  if (code && code.startsWith('HPE_')) {
    return new TransportError('protocol', `Fusion sent a malformed HTTP response (${code})`, { code });
  }
  return new TransportError('interrupted', `the connection to Fusion dropped (${code || err.message})`, { code });
}

function isResponseTo(message, id) {
  return id !== undefined && message && typeof message === 'object' && !('method' in message) && message.id === id;
}

function bodySnippet(text) {
  const flat = String(text || '').replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
  return flat ? `: ${flat.slice(0, 200)}` : '';
}

// POSTs one JSON-RPC message. Resolves with { status, sessionId, messages, text } where `messages`
// holds the reply to `expectId` (if any); every other message in the answer goes to onMessage.
function postMessage(url, message, headers, { timeoutMs, expectId, onMessage }) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const body = Buffer.from(JSON.stringify(message));
    let delivered = false;
    let settled = false;
    let req = null;

    const finish = (err, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (req) req.destroy();
      if (err) reject(err); else resolve(value);
    };
    const timer = setTimeout(() => finish(new TransportError(
      'timeout', `Fusion did not answer within ${Math.round(timeoutMs / 1000)} s`, { delivered })), timeoutMs);

    const deliver = (parsed, messages) => {
      for (const item of Array.isArray(parsed) ? parsed : [parsed]) {
        if (isResponseTo(item, expectId)) messages.push(item);
        else if (item && typeof item === 'object' && onMessage) onMessage(item);
      }
    };

    try {
      req = (target.protocol === 'https:' ? https : http).request({
        protocol: target.protocol,
        hostname: target.hostname,
        port: target.port,
        path: `${target.pathname}${target.search}`,
        method: 'POST',
        agent: false,
        // Fusion's embedded server is not a hardened web server; accept slightly odd HTTP.
        insecureHTTPParser: true,
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json, text/event-stream',
          'Content-Length': body.length,
          Connection: 'close',
          ...headers,
        },
      }, (res) => {
        const status = res.statusCode;
        const sessionId = res.headers['mcp-session-id'] || null;
        const type = String(res.headers['content-type'] || '');
        const messages = [];
        res.on('error', (err) => finish(classifySocketError(err, true)));

        if (type.includes('text/event-stream')) {
          res.setEncoding('utf8');
          let buffer = '';
          const drain = () => {
            buffer = buffer.replace(/\r\n/g, '\n');
            let end;
            while ((end = buffer.indexOf('\n\n')) !== -1) {
              const event = buffer.slice(0, end);
              buffer = buffer.slice(end + 2);
              const data = event.split('\n').filter((line) => line.startsWith('data:'))
                .map((line) => line.slice(5).replace(/^ /, '')).join('\n');
              if (!data) continue;
              try { deliver(JSON.parse(data), messages); } catch { /* not JSON: skip the event */ }
            }
            // The stream may stay open after the reply; the reply is all this request waits for.
            if (messages.length) finish(null, { status, sessionId, messages, text: '' });
          };
          res.on('data', (chunk) => { buffer += chunk; drain(); });
          res.on('end', () => { buffer += '\n\n'; drain(); finish(null, { status, sessionId, messages, text: '' }); });
          return;
        }

        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          if (status >= 200 && status < 300 && text.trim()) {
            let parsed;
            try {
              parsed = JSON.parse(text);
            } catch {
              finish(new TransportError('protocol', `Fusion answered HTTP ${status} with a body that is not JSON${bodySnippet(text)}`));
              return;
            }
            deliver(parsed, messages);
          }
          finish(null, { status, sessionId, messages, text });
        });
      });
    } catch (err) {
      finish(new TransportError('unreachable', `cannot reach ${url} (${err.message})`, { delivered: false }));
      return;
    }

    req.on('socket', (socket) => {
      if (socket.connecting) socket.once('connect', () => { delivered = true; });
      else delivered = true;
    });
    req.on('error', (err) => finish(classifySocketError(err, delivered)));
    req.end(body);
  });
}

function getJson(url, timeoutMs) {
  return new Promise((resolve) => {
    const target = new URL(url);
    const req = (target.protocol === 'https:' ? https : http).get({
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port,
      path: `${target.pathname}${target.search}`,
      agent: false,
      insecureHTTPParser: true,
      timeout: timeoutMs,
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        try {
          resolve(res.statusCode === 200 ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null);
        } catch {
          resolve(null);
        }
      });
      res.on('error', () => resolve(null));
    });
    req.on('timeout', () => req.destroy());
    req.on('error', () => resolve(null));
  });
}

// ---- Autodesk Fusion (macOS) -----------------------------------------------------------------

function fusionApp(platform, log) {
  if (platform !== 'darwin') {
    return { isRunning: async () => null, launch: async () => false };
  }
  return {
    isRunning: () => new Promise((resolve) => {
      execFile('/bin/ps', ['-axo', 'comm='], { timeout: 5000, maxBuffer: 16 * 1024 * 1024 }, (err, stdout) => {
        if (err) resolve(null);
        else resolve(stdout.split('\n').some((line) => FUSION_PROCESS.test(line.trim())));
      });
    }),
    launch: async () => {
      for (const app of FUSION_APP_NAMES) {
        // -g: start it in the background, without taking focus from what the user is doing.
        const ok = await new Promise((resolve) => {
          execFile('/usr/bin/open', ['-g', '-a', app], { timeout: 15000 }, (err) => resolve(!err));
        });
        if (ok) {
          log(`started ${app}`);
          return true;
        }
      }
      log(`could not start Autodesk Fusion (tried ${FUSION_APP_NAMES.join(', ')})`);
      return false;
    },
  };
}

// ---- the upstream MCP session ----------------------------------------------------------------

class Upstream {
  constructor(config, log) {
    this.config = config;
    this.log = log;
    this.session = null;
    this.pending = null;
    this.lastError = null;
    this.lastConnectedAt = null;
    this.connectCount = 0;
    this.requestCount = 0;
    this.onConnect = null;
  }

  endpoint() {
    if (this.config.url) return { url: this.config.url, source: 'FUSION_MCP_URL' };
    if (this.config.port) {
      return { url: `http://127.0.0.1:${this.config.port}${MCP_PATH}`, source: 'FUSION_MCP_PORT' };
    }
    const port = readConfiguredPort(this.config.settingsFile);
    if (port) {
      return { url: `http://127.0.0.1:${port}${MCP_PATH}`, source: `${PORT_SETTING} in ${this.config.settingsFile}` };
    }
    return { url: `http://127.0.0.1:${DEFAULT_PORT}${MCP_PATH}`, source: 'the Fusion-Essentials default port' };
  }

  nextId(kind) {
    this.requestCount += 1;
    return `${BRIDGE_NAME}-${kind}-${this.requestCount}`;
  }

  // One connection attempt; concurrent callers share it.
  connect(clientInit) {
    if (this.session) return Promise.resolve(this.session);
    if (!this.pending) {
      this.pending = this.openSession(clientInit).finally(() => { this.pending = null; });
    }
    return this.pending;
  }

  async openSession(clientInit) {
    const { url } = this.endpoint();
    const id = this.nextId('initialize');
    const params = {
      protocolVersion: clientInit?.protocolVersion || FALLBACK_PROTOCOL_VERSION,
      capabilities: clientInit?.capabilities || {},
      clientInfo: clientInit?.clientInfo || { name: BRIDGE_NAME, version: BRIDGE_VERSION },
    };
    try {
      const reply = await postMessage(url, { jsonrpc: '2.0', id, method: 'initialize', params }, {},
        { timeoutMs: this.config.probeTimeoutMs, expectId: id });
      if (reply.status < 200 || reply.status >= 300) {
        throw new TransportError('http', `${url} answered HTTP ${reply.status}${bodySnippet(reply.text)}`, { status: reply.status });
      }
      const response = reply.messages[0];
      if (response?.error) {
        throw new TransportError('protocol', `Fusion refused initialize: ${response.error.message}`);
      }
      const result = response?.result;
      if (!result || typeof result.protocolVersion !== 'string') {
        throw new TransportError('protocol', `${url} did not answer initialize like an MCP server`);
      }
      const session = {
        url,
        sessionId: reply.sessionId,
        protocolVersion: result.protocolVersion,
        initResult: result,
        connectedAt: Date.now(),
      };
      const ack = await this.post(session, { jsonrpc: '2.0', method: 'notifications/initialized' },
        { timeoutMs: this.config.probeTimeoutMs });
      if (ack.status >= 400) {
        throw new TransportError('http', `${url} refused notifications/initialized (HTTP ${ack.status})`, { status: ack.status });
      }
      this.session = session;
      this.lastError = null;
      this.lastConnectedAt = session.connectedAt;
      this.connectCount += 1;
      const server = result.serverInfo || {};
      this.log(`connected to ${server.name || 'an MCP server'} ${server.version || ''} at ${url} (protocol ${result.protocolVersion})`);
      if (this.onConnect) this.onConnect(session);
      return session;
    } catch (err) {
      const error = err instanceof TransportError ? err : new TransportError('protocol', err.message);
      if (this.lastError?.message !== error.message) this.log(`cannot connect to ${url}: ${error.message}`);
      this.lastError = { message: error.message, kind: error.kind, url, at: new Date().toISOString() };
      throw error;
    }
  }

  post(session, message, options) {
    const headers = { 'MCP-Protocol-Version': session.protocolVersion };
    if (session.sessionId) headers['Mcp-Session-Id'] = session.sessionId;
    return postMessage(session.url, message, headers, options);
  }

  // Forget the session (only `session`, when given, so a newer one survives a late failure).
  invalidate(session, reason) {
    if (!this.session || (session && this.session !== session)) return;
    this.session = null;
    this.log(`dropped the Fusion session: ${reason}`);
  }
}

// ---- the bridge ------------------------------------------------------------------------------

function bridgeTools() {
  return [
    {
      name: STATUS_TOOL,
      title: 'Fusion connection status',
      description: 'Reports whether Autodesk Fusion and its Fusion-Essentials MCP server are reachable: the ' +
        'address, whether Fusion is running, the add-in health and the last connection error. Call it when a ' +
        'Fusion tool fails, instead of looking at the screen.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    {
      name: RECONNECT_TOOL,
      title: 'Reconnect to Fusion',
      description: 'Drops the connection to Fusion and connects again, waiting until Fusion answers, then ' +
        'refreshes the Fusion tool list. Starts Autodesk Fusion first if it is not running (unless ' +
        'launch_fusion is false). Use it after Fusion or the add-in restarted, or when ' +
        `${STATUS_TOOL} says Fusion is unreachable.`,
      inputSchema: {
        type: 'object',
        properties: {
          launch_fusion: {
            type: 'boolean',
            description: 'Start Autodesk Fusion if it is not running. Defaults to the extension setting.',
          },
          wait_seconds: {
            type: 'number',
            minimum: 0,
            maximum: 600,
            description: 'How long to wait for Fusion to answer. Default 45.',
          },
        },
        additionalProperties: false,
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
  ];
}

function toolText(text, isError) {
  return { content: [{ type: 'text', text }], isError };
}

class Bridge {
  constructor({ config, send, log = () => {}, fusion = null }) {
    this.config = config;
    this.send = send;
    this.log = log;
    this.fusion = fusion || fusionApp(config.platform, log);
    this.upstream = new Upstream(config, log);
    this.upstream.onConnect = (session) => this.afterConnect(session);
    this.state = loadState(config.stateFile);
    this.clientInit = null;
    this.initialized = false;
    this.served = null; // the tool list Claude last received: { fingerprint, live, connectCount }
    this.waiting = new Map(); // request id -> { cancelled, progressToken, ... } while it waits or runs
    this.inFlight = new Map(); // request id -> the session it was sent on
    this.launchedAt = 0;
    this.launchFailed = false;
    this.lastRunningCheck = 0;
    this.pollTimer = null;
    this.refreshing = null;
    this.closed = false;
  }

  // ---- messages from Claude ----

  handleLine(line) {
    const text = String(line).trim();
    if (!text) return;
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      this.send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error: not JSON' } });
      return;
    }
    this.dispatch(message);
  }

  dispatch(message) {
    if (Array.isArray(message)) {
      message.forEach((item) => this.dispatch(item));
      return;
    }
    if (!message || typeof message !== 'object') return;
    if (typeof message.method === 'string') {
      if ('id' in message) {
        this.handleRequest(message).catch((err) => {
          this.log(`${message.method} failed: ${err.stack || err.message}`);
          this.replyError(message.id, -32603, err.message);
        });
      } else {
        this.handleNotification(message).catch((err) => this.log(`${message.method} failed: ${err.message}`));
      }
    } else if ('id' in message) {
      // Claude answering a request Fusion sent it.
      this.passUpstream(message).catch((err) => this.log(`could not pass a reply to Fusion: ${err.message}`));
    }
  }

  async handleRequest(message) {
    switch (message.method) {
      case 'initialize':
        return this.onInitialize(message);
      case 'ping':
        return this.reply(message.id, {});
      case 'tools/list':
        return this.onToolsList(message);
      case 'tools/call': {
        const name = message.params?.name;
        if (name === STATUS_TOOL) return this.reply(message.id, await this.statusResult());
        if (name === RECONNECT_TOOL) return this.reconnect(message);
        return this.forward(message, { toolCall: true });
      }
      default:
        return this.forward(message, { toolCall: false });
    }
  }

  async handleNotification(message) {
    if (message.method === 'notifications/initialized') {
      this.initialized = true;
      return;
    }
    if (message.method === 'notifications/cancelled') {
      const id = message.params?.requestId;
      const waiting = this.waiting.get(id);
      if (waiting) waiting.cancelled = true;
      const session = this.inFlight.get(id);
      if (session) await this.upstream.post(session, message, { timeoutMs: this.config.probeTimeoutMs }).catch(() => {});
      return;
    }
    await this.passUpstream(message);
  }

  // Best effort, on the current session only: a notification or reply is meaningless on a new one.
  async passUpstream(message) {
    const session = this.upstream.session;
    if (!session) return;
    await this.upstream.post(session, message, {
      timeoutMs: this.config.probeTimeoutMs,
      onMessage: (item) => this.fromUpstream(item),
    });
  }

  // ---- initialize and tools/list ----

  async onInitialize(message) {
    this.clientInit = message.params || {};
    let result = null;
    try {
      const session = await this.ensureSession({ deadline: Date.now() + this.config.listWaitMs, launch: false });
      result = session.initResult;
    } catch {
      result = this.state.initResult || null;
    }
    this.reply(message.id, this.presentInitialize(result));
  }

  presentInitialize(upstream) {
    const base = upstream || {
      protocolVersion: this.clientInit?.protocolVersion || FALLBACK_PROTOCOL_VERSION,
      capabilities: { tools: {} },
      serverInfo: { name: BRIDGE_NAME, version: BRIDGE_VERSION },
    };
    const capabilities = { ...(base.capabilities || {}) };
    // The bridge tells Claude when Fusion's tools change (Fusion came up, the add-in reloaded).
    capabilities.tools = { ...(capabilities.tools || {}), listChanged: true };
    return {
      protocolVersion: base.protocolVersion,
      capabilities,
      serverInfo: base.serverInfo || { name: BRIDGE_NAME, version: BRIDGE_VERSION },
      instructions: [base.instructions, BRIDGE_INSTRUCTIONS].filter(Boolean).join('\n\n'),
    };
  }

  async onToolsList(message) {
    if (message.params?.cursor) {
      await this.forward(message, { toolCall: false });
      return;
    }
    let tools;
    let nextCursor;
    let live = false;
    try {
      ({ tools, nextCursor } = await this.fetchTools(this.config.listWaitMs));
      live = true;
    } catch (err) {
      tools = Array.isArray(this.state.tools) ? this.state.tools : [];
      this.log(`answered tools/list from the cache (${tools.length} Fusion tools): ${err.message}`);
    }
    this.served = { fingerprint: fingerprint(tools), live, connectCount: this.upstream.connectCount };
    if (!live) this.startPolling();
    const result = { tools: [...tools, ...bridgeTools()] };
    if (nextCursor) result.nextCursor = nextCursor;
    this.reply(message.id, result);
  }

  async fetchTools(waitMs) {
    const request = { jsonrpc: '2.0', id: this.upstream.nextId('tools'), method: 'tools/list', params: {} };
    const response = await this.request(request, { waitMs, launch: false, readOnly: true });
    if (!response || response === CANCELLED) throw new Error('Fusion sent no tool list');
    if (response.error) throw new Error(`Fusion refused tools/list: ${response.error.message}`);
    const result = response.result || {};
    const tools = Array.isArray(result.tools) ? result.tools : [];
    this.saveState({ tools });
    return { tools, nextCursor: result.nextCursor };
  }

  afterConnect(session) {
    this.saveState({ initResult: session.initResult, url: session.url });
    // Claude holds a tool list from before this session: check it is still the right one.
    if (this.initialized && this.served && this.served.connectCount !== this.upstream.connectCount) {
      setImmediate(() => this.refreshTools().catch((err) => this.log(`tool refresh failed: ${err.message}`)));
    }
  }

  // Re-reads Fusion's tools; tells Claude when they differ from what it has. Returns the count.
  refreshTools() {
    if (!this.refreshing) {
      this.refreshing = (async () => {
        const { tools } = await this.fetchTools(0);
        const current = fingerprint(tools);
        const changed = !this.served || this.served.fingerprint !== current;
        this.served = { fingerprint: current, live: true, connectCount: this.upstream.connectCount };
        this.stopPolling();
        if (changed && this.initialized) {
          this.log(`Fusion's tools changed (${tools.length} now); asking Claude to reload them`);
          this.send({ jsonrpc: '2.0', method: 'notifications/tools/list_changed' });
        }
        return { count: tools.length, changed };
      })().finally(() => { this.refreshing = null; });
    }
    return this.refreshing;
  }

  startPolling() {
    if (this.pollTimer || this.closed || !this.config.pollMs) return;
    this.pollTimer = setInterval(() => {
      if (this.upstream.session) {
        if (this.served && !this.served.live) {
          this.refreshTools().catch(() => {});
        } else {
          this.stopPolling();
        }
        return;
      }
      // A successful connect refreshes the tool list (afterConnect).
      this.upstream.connect(this.clientInit).catch(() => {});
    }, this.config.pollMs);
    this.pollTimer.unref?.();
  }

  stopPolling() {
    if (this.pollTimer) clearInterval(this.pollTimer);
    this.pollTimer = null;
  }

  // ---- forwarding ----

  isReadOnlyTool(name) {
    const tool = Array.isArray(this.state.tools) ? this.state.tools.find((t) => t?.name === name) : null;
    return tool?.annotations?.readOnlyHint === true;
  }

  async forward(message, { toolCall }) {
    const context = { cancelled: false, progressToken: message.params?._meta?.progressToken, lastProgress: Date.now() };
    this.waiting.set(message.id, context);
    const readOnly = READ_ONLY_METHODS.has(message.method) || (toolCall && this.isReadOnlyTool(message.params?.name));
    try {
      const response = await this.request(message, {
        waitMs: this.config.connectWaitMs,
        launch: toolCall && this.config.autoLaunch,
        readOnly,
        context,
      });
      if (context.cancelled || response === CANCELLED) return;
      if (!response) {
        this.replyError(message.id, -32000, 'Fusion accepted the request but sent no reply.');
        return;
      }
      this.send(response);
    } catch (err) {
      if (context.cancelled) return;
      let text = err instanceof UnreachableError ? err.message : `The request to Fusion failed: ${err.message}.`;
      if (toolCall && !readOnly && err.delivered && (err.kind === 'interrupted' || err.kind === 'timeout')) {
        text += ' Fusion received it, so it may or may not have taken effect: check the design ' +
          '(for example with workspace_orient) before running it again.';
      }
      if (toolCall) {
        this.reply(message.id, toolText(text, true));
      } else if (LIST_RESULT_KEYS[message.method] && err instanceof UnreachableError) {
        this.reply(message.id, { [LIST_RESULT_KEYS[message.method]]: [] });
      } else {
        this.replyError(message.id, -32000, text);
      }
    } finally {
      this.waiting.delete(message.id);
    }
  }

  // Sends one request to Fusion, reconnecting as needed, and returns Fusion's reply (null when
  // Fusion sent none, CANCELLED when Claude cancelled). A request is sent again only when it
  // certainly never reached Fusion, Fusion refused its session, or it changes nothing.
  async request(message, { waitMs, launch, readOnly, context = null }) {
    const deadline = Date.now() + waitMs;
    let sessionRefusals = 0;
    let resends = 0;
    for (;;) {
      if (context?.cancelled) return CANCELLED;
      const session = await this.ensureSession({ deadline, launch, context });
      if (context?.cancelled) return CANCELLED;

      let reply;
      if (message.id !== undefined) this.inFlight.set(message.id, session);
      try {
        reply = await this.upstream.post(session, message, {
          timeoutMs: this.config.requestTimeoutMs,
          expectId: message.id,
          onMessage: (item) => this.fromUpstream(item),
        });
      } catch (err) {
        this.upstream.invalidate(session, err.message);
        const again = !err.delivered || (readOnly && resends < 2);
        if (!again || Date.now() >= deadline) throw err;
        resends += 1;
        this.log(`sending ${message.method} again: ${err.message}`);
        await sleep(250);
        continue;
      } finally {
        if (message.id !== undefined) this.inFlight.delete(message.id);
      }

      if (reply.status === 404 && session.sessionId) {
        // Fusion restarted, or the add-in reloaded, and no longer knows the session.
        this.upstream.invalidate(session, 'Fusion no longer knows the session (Fusion or the add-in restarted)');
        sessionRefusals += 1;
        if (sessionRefusals > 3) throw new TransportError('http', 'Fusion keeps refusing new sessions (HTTP 404)', { status: 404 });
        continue;
      }
      if (reply.status < 200 || reply.status >= 300) {
        throw new TransportError('http', `Fusion answered HTTP ${reply.status}${bodySnippet(reply.text)}`, { status: reply.status });
      }
      return reply.messages[0] || null;
    }
  }

  async ensureSession({ deadline, launch, context = null }) {
    let delay = 250;
    let lastError = null;
    for (;;) {
      try {
        return await this.upstream.connect(this.clientInit);
      } catch (err) {
        lastError = err;
      }
      if (context?.cancelled) throw new UnreachableError('cancelled');
      if (launch) await this.maybeLaunchFusion();
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new UnreachableError(await this.explainUnreachable(lastError, launch));
      this.reportWaiting(context);
      await sleep(Math.min(delay, remaining));
      delay = Math.min(delay * 2, 2000);
    }
  }

  async maybeLaunchFusion() {
    const now = Date.now();
    if (now - this.launchedAt < this.config.launchSettleMs || now - this.lastRunningCheck < 5000) return;
    this.lastRunningCheck = now;
    if ((await this.fusion.isRunning()) !== false) return;
    this.launchedAt = now;
    this.launchFailed = !(await this.fusion.launch());
  }

  reportWaiting(context) {
    if (context?.progressToken === undefined || Date.now() - context.lastProgress < 5000) return;
    context.lastProgress = Date.now();
    context.progress = (context.progress || 0) + 1;
    this.send({
      jsonrpc: '2.0',
      method: 'notifications/progress',
      params: { progressToken: context.progressToken, progress: context.progress, message: 'Waiting for Autodesk Fusion to answer' },
    });
  }

  async explainUnreachable(lastError, launch) {
    const { url } = this.upstream.endpoint();
    const running = await this.fusion.isRunning();
    const starting = this.launchedAt && Date.now() - this.launchedAt < this.config.launchSettleMs;
    const after = ` Call ${RECONNECT_TOOL} to try again.`;
    if (running === false) {
      if (starting && !this.launchFailed) {
        return 'Autodesk Fusion is starting (the bridge started it). It can take a minute or two, plus ' +
          'signing in if Fusion asks, before the Fusion-Essentials add-in answers.' + after;
      }
      return `Autodesk Fusion is not running${launch ? ' and could not be started' : ''}. Open Fusion, ` +
        `or call ${RECONNECT_TOOL} with launch_fusion=true.`;
    }
    if (lastError?.kind === 'timeout') {
      return `Fusion did not answer at ${url} in time. It may be busy with a long operation or waiting ` +
        'for someone to close a dialog.' + after;
    }
    if (!lastError || lastError.kind === 'unreachable' || !lastError.delivered) {
      const who = running === true ? 'Autodesk Fusion is running, but nothing' : 'Nothing';
      return `${who} answers at ${url}. The Fusion-Essentials add-in is not running, or its MCP server is ` +
        'switched off. In Fusion open Utilities > Add-Ins > Scripts and Add-Ins, select Fusion-Essentials, ' +
        'click Run and tick Run on Startup; if it runs, tick Enable MCP Server in Fusion Essentials Settings ' +
        'and reload the add-in.' + (running === null ? ' (Also check that Fusion is open.)' : '') + after;
    }
    return `Fusion's MCP server at ${url} is not working: ${lastError.message}.` + after;
  }

  // Messages Fusion sent besides the reply being waited for: notifications, or requests for Claude.
  fromUpstream(message) {
    this.send(message);
  }

  // ---- the bridge's own tools ----

  async statusResult() {
    let summary;
    try {
      await this.ensureSession({ deadline: Date.now() + 2000, launch: false });
    } catch (err) {
      summary = err.message;
    }
    const session = this.upstream.session;
    const endpoint = this.upstream.endpoint();
    const health = await getJson(new URL('/health', endpoint.url).href, 2000);
    const server = session?.initResult?.serverInfo || null;
    if (session) {
      summary = `Connected to ${server?.name || 'the Fusion MCP server'} ${server?.version || ''} at ${session.url}.`.replace(/ {2}/g, ' ');
    }
    summary = summary || 'Not connected to Fusion.';
    const status = {
      connected: Boolean(session),
      url: endpoint.url,
      url_from: endpoint.source,
      fusion_running: await this.fusion.isRunning(),
      add_in_health: health && typeof health === 'object'
        ? { status: health.status, server: health.server, version: health.version, bound: health.bound }
        : null,
      server,
      protocol_version: session?.protocolVersion || null,
      connected_since: session ? new Date(session.connectedAt).toISOString() : null,
      sessions_opened: this.upstream.connectCount,
      last_error: session ? null : this.upstream.lastError,
      cached_tools: Array.isArray(this.state.tools) ? this.state.tools.length : 0,
      auto_launch_fusion: this.config.autoLaunch,
      log_file: this.config.logFile,
      bridge_version: BRIDGE_VERSION,
    };
    return toolText(`${summary}\n\n${JSON.stringify(status, null, 2)}`, false);
  }

  async reconnect(message) {
    const args = message.params?.arguments || {};
    const launch = typeof args.launch_fusion === 'boolean' ? args.launch_fusion : this.config.autoLaunch;
    const seconds = Number.isFinite(args.wait_seconds) ? Math.min(Math.max(args.wait_seconds, 0), 600) : 45;
    const context = { cancelled: false, progressToken: message.params?._meta?.progressToken, lastProgress: Date.now() };
    this.waiting.set(message.id, context);
    try {
      this.upstream.invalidate(null, 'reconnect requested');
      if (launch) this.launchedAt = 0;
      const session = await this.ensureSession({ deadline: Date.now() + seconds * 1000, launch, context });
      const { count, changed } = await this.refreshTools();
      if (context.cancelled) return;
      const server = session.initResult?.serverInfo?.name || 'the Fusion MCP server';
      this.reply(message.id, toolText(
        `Reconnected to ${server} at ${session.url}. ${count} Fusion tools are available.` +
        (changed ? ' The tool list changed, and Claude has been told to reload it.' : ''), false));
    } catch (err) {
      if (!context.cancelled) this.reply(message.id, toolText(err.message, true));
    } finally {
      this.waiting.delete(message.id);
    }
  }

  // ---- plumbing ----

  saveState(patch) {
    Object.assign(this.state, patch, { savedAt: new Date().toISOString(), bridgeVersion: BRIDGE_VERSION });
    try {
      writeStateFile(this.config.stateFile, this.state);
    } catch (err) {
      this.log(`could not save ${this.config.stateFile}: ${err.message}`);
    }
  }

  reply(id, result) {
    this.send({ jsonrpc: '2.0', id, result });
  }

  replyError(id, code, message) {
    this.send({ jsonrpc: '2.0', id, error: { code, message } });
  }

  close() {
    this.closed = true;
    this.stopPolling();
  }
}

module.exports = {
  BRIDGE_VERSION,
  Bridge,
  createLogger,
  loadConfig,
  readConfiguredPort,
};
