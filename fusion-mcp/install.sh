#!/bin/bash
# Sets up Fusion-Essentials (https://github.com/Philip-Mestenhauser/Fusion-Essentials) for Claude
# Desktop and Cowork on a Mac:
#   1. puts the add-in in Fusion's add-ins folder, so Fusion lists it and can run it at startup;
#   2. switches the add-in's MCP server on in its settings file;
#   3. installs the "Fusion (Fusion-Essentials)" extension in Claude Desktop, which keeps Claude
#      connected to the add-in while Fusion restarts.
#
# Run it in Terminal:
#   curl -fsSL https://raw.githubusercontent.com/capceri/ftp-plus-oauth/main/fusion-mcp/install.sh | bash
#
# Optional environment variables:
#   FUSION_ESSENTIALS_REF  Fusion-Essentials commit, tag or branch to install (default: the tested commit)
#   BRIDGE_REF             ftp-plus-oauth branch or commit to take the extension from (default: main)
#   FUSION_ADDINS_DIR      Fusion's add-ins folder, if this script picks the wrong one
#   NO_OPEN=1              build the extension but do not open it in Claude Desktop
set -euo pipefail

TESTED_FUSION_ESSENTIALS_REF=925e8c11840bacc4682290143c3068e04e3a3ade
FE_REF="${FUSION_ESSENTIALS_REF:-$TESTED_FUSION_ESSENTIALS_REF}"
BRIDGE_REF="${BRIDGE_REF:-main}"
SUPPORT_DIR="$HOME/Library/Application Support/Fusion MCP Bridge"
STORE_HOME="$HOME/Library/Containers/com.autodesk.mas.fusion360/Data"
MCP_PORT=37182

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf '\nError: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "this installer is for macOS."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Fusion's add-ins folder. A direct download keeps it in Application Support, the Mac App Store
# version inside its sandbox; the folder is called "Autodesk Fusion 360" or "Autodesk Fusion"
# depending on the Fusion version, so take the one Fusion touched most recently.
pick_addins_dir() {
  if [[ -n "${FUSION_ADDINS_DIR:-}" ]]; then
    printf '%s\n' "$FUSION_ADDINS_DIR"
    return
  fi
  local base="$HOME/Library/Application Support/Autodesk"
  if [[ ! -d "$base/webdeploy" && -d "$STORE_HOME" ]]; then
    base="$STORE_HOME/Library/Application Support/Autodesk"
  fi
  local best="" best_time=-1 api stamp
  for api in "$base/Autodesk Fusion 360/API" "$base/Autodesk Fusion/API"; do
    [[ -d "$api" ]] || continue
    stamp="$(stat -f %m "$api" 2>/dev/null || echo 0)"
    if [[ -d "$api/AddIns" ]]; then
      local addins_stamp
      addins_stamp="$(stat -f %m "$api/AddIns" 2>/dev/null || echo 0)"
      (( addins_stamp > stamp )) && stamp="$addins_stamp"
    fi
    if (( stamp > best_time )); then
      best="$api"
      best_time="$stamp"
    fi
  done
  printf '%s\n' "${best:-$base/Autodesk Fusion 360/API}/AddIns"
}

# Not pgrep: it matches the first 16 characters of a name, and "Autodesk Fusion 360" is longer.
# The listing is read in full first so grep -q cannot cut ps off (which pipefail counts as failure).
# GitHub serves a commit, tag or plain branch at archive/<ref>, and a branch with a slash in its
# name at archive/refs/heads/<ref>.
download_archive() { # <owner/repo> <ref> <output file>
  curl -fsSL "https://github.com/$1/archive/$2.tar.gz" -o "$3" 2>/dev/null \
    || curl -fsSL "https://github.com/$1/archive/refs/heads/$2.tar.gz" -o "$3"
}

fusion_running() {
  local processes
  processes="$(ps -axo comm=)"
  grep -Eq '(^|/)Autodesk Fusion( 360)?$' <<<"$processes"
}

# --- the files this installer needs (beside it in a checkout, else downloaded)
kit=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$here/bridge/manifest.json" ]] && kit="$here"
fi
if [[ -z "$kit" ]]; then
  step "Downloading the Claude extension (capceri/ftp-plus-oauth, $BRIDGE_REF)"
  download_archive capceri/ftp-plus-oauth "$BRIDGE_REF" "$work/kit.tgz" \
    || die "could not download https://github.com/capceri/ftp-plus-oauth ($BRIDGE_REF)."
  mkdir "$work/kit"
  tar -xzf "$work/kit.tgz" -C "$work/kit"
  manifest="$(find "$work/kit" -path '*/fusion-mcp/bridge/manifest.json' -print -quit)"
  [[ -n "$manifest" ]] || die "the download has no fusion-mcp/bridge/manifest.json."
  kit="$(dirname "$(dirname "$manifest")")"
fi

# --- 1. the add-in
step "Downloading Fusion-Essentials ($FE_REF)"
download_archive Philip-Mestenhauser/Fusion-Essentials "$FE_REF" "$work/fe.tgz" \
  || die "could not download Fusion-Essentials ($FE_REF)."
mkdir "$work/fe"
tar -xzf "$work/fe.tgz" -C "$work/fe"
fe_manifest="$(find "$work/fe" -maxdepth 2 -name 'Fusion-Essentials.manifest' -print -quit)"
[[ -n "$fe_manifest" ]] || die "the Fusion-Essentials download has no Fusion-Essentials.manifest."
fe_src="$(dirname "$fe_manifest")"
[[ -f "$fe_src/Fusion-Essentials.py" && -d "$fe_src/commands" && -d "$fe_src/lib" ]] \
  || die "the Fusion-Essentials download does not look like the add-in."

addins_dir="$(pick_addins_dir)"
addin_dir="$addins_dir/Fusion-Essentials"
step "Installing the add-in in $addins_dir"
mkdir -p "$addins_dir"
if [[ -e "$addin_dir" || -L "$addin_dir" ]]; then
  backup="$SUPPORT_DIR/backups/Fusion-Essentials-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$(dirname "$backup")"
  mv "$addin_dir" "$backup"
  say "The copy that was there is now in $backup"
fi
# The folder has to be called Fusion-Essentials: the add-in takes its name from it.
ditto "$fe_src" "$addin_dir"
say "Installed Fusion-Essentials $(sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$addin_dir/Fusion-Essentials.manifest")"

# --- 2. its MCP server
# The add-in keeps its settings under the home folder Fusion runs with (the sandbox for the App Store version).
case "$addins_dir" in
  "$STORE_HOME"/*) addin_home="$STORE_HOME" ;;
  *) addin_home="$HOME" ;;
esac
settings_file="$addin_home/Library/Application Support/GTF_Fusion-Essentials/FusionEssentialsSettings.json"
step "Switching on the add-in's MCP server"
result="$(osascript -l JavaScript "$kit/scripts/enable_mcp_setting.js" "$settings_file" "$addin_dir")" \
  || die "could not update $settings_file."
say "MCP server $result ($settings_file)"

# --- 3. the Claude Desktop extension
step "Building the Claude Desktop extension"
mkdir -p "$SUPPORT_DIR"
mcpb="$SUPPORT_DIR/Fusion-Essentials.mcpb"
bash "$kit/scripts/pack_mcpb.sh" "$mcpb" >/dev/null
say "Built $mcpb"
opened=0
if [[ "${NO_OPEN:-}" == 1 ]]; then
  say "Not opening it in Claude Desktop (NO_OPEN=1)."
elif open -a Claude "$mcpb" 2>/dev/null; then
  opened=1
  say "Opened it in Claude Desktop."
else
  say "Claude Desktop was not found. Install it, then double-click $mcpb."
fi

{
  printf 'installed %s\n' "$(date)"
  printf 'fusion-essentials %s -> %s\n' "$FE_REF" "$addin_dir"
  printf 'settings %s\n' "$settings_file"
  printf 'extension %s (from %s)\n' "$mcpb" "$kit"
} > "$SUPPORT_DIR/install.txt"

# --- where things stand
step "Checking Fusion"
addin_ready=0
if fusion_running; then
  health="$(curl -fsS --max-time 2 "http://127.0.0.1:$MCP_PORT/health" 2>/dev/null || true)"
  if [[ "$health" == *'Fusion-Essentials MCP Server'* ]]; then
    addin_ready=1
    say "Fusion is running and the Fusion-Essentials MCP server answers on port $MCP_PORT."
  else
    say "Fusion is running, but the add-in's MCP server is not answering yet (step 2 below)."
  fi
else
  say "Fusion is not running. Open it for step 2 below."
fi

cat <<EOF

Done. To finish, once:

  1. Claude Desktop: $( ((opened)) && echo "click Install in the window that opened." || echo "open $mcpb to install the extension.")
     It is listed as "Fusion (Fusion-Essentials)" in Settings > Extensions. If Autodesk's own
     Fusion connector is installed there too, turn it off so Claude sees one set of Fusion tools.

  2. Fusion: $( ((addin_ready)) && echo "nothing to do, the add-in is already running." || echo "press Shift+S, open the Add-Ins tab, select Fusion-Essentials, tick
     \"Run on Startup\" and click Run. (If Fusion-Essentials is not in the list, click + next to
     My Add-Ins and choose $addin_dir.)")

  3. Start a new Cowork task and ask "what do I have open in Fusion?".

After that the connection looks after itself: Claude's extension reconnects when Fusion or the
add-in restarts and starts Fusion when a Fusion tool needs it. If something is still wrong,
Claude can call fusion_connection_status to say what.
EOF
