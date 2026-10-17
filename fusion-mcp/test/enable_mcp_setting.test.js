'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const { main } = require('../scripts/enable_mcp_setting');
const { tempDir } = require('./helpers/bridge-client');

const ADD_IN = '/Users/me/Library/Application Support/Autodesk/Autodesk Fusion 360/API/AddIns/Fusion-Essentials';
const read = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));

test('creates the settings file with the MCP server switched on', () => {
  const file = path.join(tempDir(), 'GTF_Fusion-Essentials', 'FusionEssentialsSettings.json');
  assert.equal(main([file, ADD_IN]), 'enabled');
  assert.deepEqual(read(file), {
    FEATURE_ENABLEMENT: {
      name: 'Settings',
      settings: {
        'GTF_Fusion-Essentials_MCP_Server': { type: 'checkbox', label: 'Enable MCP Server', default: true },
      },
      img_path: `${ADD_IN}/commands/resources/settings/`,
    },
  });
});

test('switches the MCP server on and leaves every other setting alone', () => {
  const file = path.join(tempDir(), 'FusionEssentialsSettings.json');
  const before = {
    FEATURE_ENABLEMENT: {
      name: 'Settings',
      settings: {
        'GTF_Fusion-Essentials_Color_Holes': { type: 'checkbox', label: 'Enable Color Holes', default: false },
        'GTF_Fusion-Essentials_MCP_Server': { type: 'checkbox', label: 'Enable MCP Server', default: false },
      },
      img_path: '/old/path/commands/resources/settings/',
    },
    'GTF_Fusion-Essentials_MCP': { name: 'MCP Server', settings: { mcp_port: { type: 'number', default: 40000 } } },
  };
  fs.writeFileSync(file, JSON.stringify(before));
  assert.equal(main([file, ADD_IN]), 'enabled');
  const after = read(file);
  before.FEATURE_ENABLEMENT.settings['GTF_Fusion-Essentials_MCP_Server'].default = true;
  assert.deepEqual(after, before);

  const written = fs.statSync(file).mtimeMs;
  assert.equal(main([file, ADD_IN]), 'already enabled');
  assert.equal(fs.statSync(file).mtimeMs, written, 'nothing to change, nothing written');
});

test('brings the add-in’s old flat format into the current one', () => {
  const file = path.join(tempDir(), 'FusionEssentialsSettings.json');
  fs.writeFileSync(file, JSON.stringify({
    FEATURE_ENABLEMENT: { 'GTF_Fusion-Essentials_Add_Holder': { type: 'checkbox', label: 'Enable Add Holder', default: true } },
  }));
  main([file, ADD_IN]);
  const group = read(file).FEATURE_ENABLEMENT;
  assert.equal(group.name, 'Settings');
  assert.equal(group.settings['GTF_Fusion-Essentials_Add_Holder'].default, true);
  assert.equal(group.settings['GTF_Fusion-Essentials_MCP_Server'].default, true);
});

test('refuses to touch a settings file that is not JSON', () => {
  const file = path.join(tempDir(), 'FusionEssentialsSettings.json');
  fs.writeFileSync(file, '{ not json');
  assert.throws(() => main([file, ADD_IN]), SyntaxError);
  assert.equal(fs.readFileSync(file, 'utf8'), '{ not json');
});
