#!/usr/bin/env node
'use strict';

// Entry point Claude Desktop runs: MCP over stdio (one JSON-RPC message per line) to Claude,
// Streamable HTTP to Fusion-Essentials. stdout carries protocol messages only; logs go to stderr
// (Claude keeps them in its MCP logs) and to the bridge's own log file.

const readline = require('node:readline');
const { BRIDGE_VERSION, Bridge, createLogger, loadConfig } = require('./bridge');

const config = loadConfig();
const log = createLogger(config.logFile);
const bridge = new Bridge({
  config,
  log,
  send: (message) => { process.stdout.write(`${JSON.stringify(message)}\n`); },
});

log(`fusion-mcp-bridge ${BRIDGE_VERSION} started (pid ${process.pid}); Fusion endpoint ${bridge.upstream.endpoint().url}`);

const exit = (why) => {
  log(`exiting: ${why}`);
  bridge.close();
  process.exit(0);
};

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', (line) => bridge.handleLine(line));
input.on('close', () => exit('Claude closed the connection'));
process.stdout.on('error', (err) => exit(`stdout closed (${err.code || err.message})`));

// Nothing Fusion does may take the connector down: log it and keep serving.
process.on('uncaughtException', (err) => log(`unexpected error, still running: ${err.stack || err}`));
process.on('unhandledRejection', (err) => log(`unhandled rejection, still running: ${(err && err.stack) || err}`));
for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, () => exit(signal));
