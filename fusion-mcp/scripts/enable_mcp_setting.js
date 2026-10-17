// Switches on the Fusion-Essentials MCP server in the add-in's settings file, so the add-in starts
// the server the next time it loads, without anyone opening its Settings dialog. Every other
// setting is left as it is; the add-in fills in any missing ones itself when it loads.
//
// Runs under the JavaScript built into macOS, or under Node (for the tests):
//   osascript -l JavaScript enable_mcp_setting.js <FusionEssentialsSettings.json> <add-in folder>
//   node enable_mcp_setting.js <FusionEssentialsSettings.json> <add-in folder>
// Prints "enabled" or "already enabled".

const FEATURE_GROUP = 'FEATURE_ENABLEMENT';
const MCP_FEATURE = 'GTF_Fusion-Essentials_MCP_Server';

function enableMcp(settings, addInDir) {
  const all = settings && typeof settings === 'object' && !Array.isArray(settings) ? settings : {};
  const icons = `${addInDir.replace(/\/+$/, '')}/commands/resources/settings/`;
  let group = all[FEATURE_GROUP];
  if (!group || typeof group !== 'object' || !group.settings || typeof group.settings !== 'object') {
    // Missing, or the add-in's old format that kept the rows directly in the group.
    group = { name: 'Settings', settings: group && typeof group === 'object' ? group : {}, img_path: icons };
    all[FEATURE_GROUP] = group;
  }
  if (!group.name) group.name = 'Settings';
  if (!group.img_path) group.img_path = icons;
  const row = group.settings[MCP_FEATURE];
  const wasOn = Boolean(row && row.default === true);
  group.settings[MCP_FEATURE] = { type: 'checkbox', label: 'Enable MCP Server', ...(row || {}), default: true };
  return { settings: all, changed: !wasOn };
}

function readText(file) {
  if (typeof ObjC !== 'undefined') {
    ObjC.import('Foundation');
    const text = $.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null);
    return text.isNil() ? null : ObjC.unwrap(text);
  }
  const fs = require('fs');
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
}

function writeText(file, text) {
  if (typeof ObjC !== 'undefined') {
    ObjC.import('Foundation');
    const folder = $(file).stringByDeletingLastPathComponent;
    $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(folder, true, $(), null);
    if (!$(text).writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null)) {
      throw new Error(`could not write ${file}`);
    }
    return;
  }
  const fs = require('fs');
  const path = require('path');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(`${file}.tmp`, text);
  fs.renameSync(`${file}.tmp`, file);
}

function main(argv) {
  const file = argv[0];
  const addInDir = argv[1];
  if (!file || !addInDir) throw new Error('usage: enable_mcp_setting.js <FusionEssentialsSettings.json> <add-in folder>');
  const text = readText(file);
  // A settings file that is not JSON is left alone: better to stop than to lose someone's settings.
  const current = text && text.trim() ? JSON.parse(text) : {};
  const { settings, changed } = enableMcp(current, addInDir);
  if (changed) writeText(file, JSON.stringify(settings, null, 4));
  return changed ? 'enabled' : 'already enabled';
}

// osascript runs run(argv) and prints what it returns.
// eslint-disable-next-line no-unused-vars
function run(argv) {
  return main(argv);
}

if (typeof module !== 'undefined') {
  module.exports = { enableMcp, main };
  if (require.main === module) console.log(main(process.argv.slice(2)));
}
