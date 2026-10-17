# Fusion for Claude (Fusion-Essentials)

Sets up [Fusion-Essentials](https://github.com/Philip-Mestenhauser/Fusion-Essentials) on a Mac so
Claude Desktop and Cowork can work in your open Autodesk Fusion session, and keeps that connection
up without anyone having to restart Fusion or Claude by hand.

Fusion-Essentials is a Fusion add-in with its own MCP server (a couple of hundred typed Fusion
tools that check their own results). It runs inside Fusion at `http://127.0.0.1:37182/mcp`.
Claude Desktop does not talk to that address directly. It talks to the small **Fusion
(Fusion-Essentials)** extension in this folder, and the extension talks to the add-in.

## Install

In Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/capceri/ftp-plus-oauth/main/fusion-mcp/install.sh | bash
```

The script:

1. downloads Fusion-Essentials (the commit tested here) into Fusion's add-ins folder, as
   `…/API/AddIns/Fusion-Essentials`. Anything already there is moved to
   `~/Library/Application Support/Fusion MCP Bridge/backups`;
2. switches the add-in's MCP server on in its settings file, so you never need its Settings dialog;
3. builds the extension (`~/Library/Application Support/Fusion MCP Bridge/Fusion-Essentials.mcpb`)
   and opens it in Claude Desktop.

Then, once:

1. **Claude Desktop:** click **Install** in the extension window. If Autodesk's own Fusion
   connector is installed (Settings › Extensions or Connectors), turn it off so Claude sees one set
   of Fusion tools.
2. **Fusion:** press **Shift+S**, open the **Add-Ins** tab, select **Fusion-Essentials**, tick
   **Run on Startup** and click **Run**. If it is not listed, click **+** next to *My Add-Ins* and
   choose the folder the script printed.
3. Start a new Cowork task and ask *"what do I have open in Fusion?"*.

Running the script again updates both parts. Fusion-Essentials is tested by its author on Windows;
on macOS it is untested upstream. If a Fusion tool misbehaves (rather than the connection), that is
one for [Fusion-Essentials' issues](https://github.com/Philip-Mestenhauser/Fusion-Essentials/issues).

## Why the connection stays up

A plain connection to Fusion drops whenever Fusion closes, starts, or reloads the add-in: the add-in
forgets every MCP session when it restarts, and Claude marks the connector as failed and leaves it
there until Claude itself restarts. The extension sits in between and never goes down on Claude's
side:

- **Fusion forgot the session** (Fusion or the add-in restarted): it opens a new one and sends the
  request again. Fusion refused the old session before running anything, so nothing runs twice.
- **Fusion is closed:** a Fusion tool call starts Fusion in the background (without taking focus)
  and waits up to 45 seconds for the add-in to answer. If Fusion takes longer to start, Claude is
  told so and tries again.
- **Fusion is not there when Claude starts:** Claude still gets the Fusion tool list, from the
  extension's cache. When Fusion appears, the extension tells Claude if the tools changed.
- **The connection drops mid-call:** a read-only tool is asked again. A tool that changes the
  design is not repeated blindly: Claude is told the outcome is unknown and checks the design.
- **Fusion hangs:** the call gives up after 5 minutes and the next one starts afresh.
- **The add-in's port changed** (`mcp_port` in its settings file): the extension follows it.

It adds two tools of its own, so Claude can sort out the connection without operating your screen:

- `fusion_connection_status`: is Fusion running, does the add-in answer, what went wrong last.
- `fusion_reconnect`: connect again (starting Fusion if needed) and reload the tool list.

When something does need you, such as the add-in not running or a dialog open in Fusion, Claude
gets a sentence saying exactly what to do.

## Settings

In Claude Desktop, under Settings › Extensions › Fusion (Fusion-Essentials):

- **Start Fusion when needed** (on): start Fusion when a Fusion tool is used while it is closed.
- **Seconds to wait for Fusion** (45): how long a tool call waits for Fusion to answer. Keep it
  under 60: Claude stops waiting for a tool after about a minute.

The extension also reads these environment variables, for use outside Claude Desktop:
`FUSION_MCP_URL`, `FUSION_MCP_PORT`, `FUSION_AUTO_LAUNCH`, `FUSION_CONNECT_WAIT_SECONDS`,
`FUSION_REQUEST_TIMEOUT_SECONDS`. To use it from Claude Code:

```bash
claude mcp add fusion -- node "/path/to/fusion-mcp/bridge/server/index.js"
```

## When something is wrong

- Ask Claude to call `fusion_connection_status`. It names the problem and the fix.
- The extension's log: `~/Library/Logs/Fusion MCP Bridge/bridge.log`. Claude Desktop keeps its own
  MCP logs in `~/Library/Logs/Claude/`.
- Is the add-in answering? Open <http://127.0.0.1:37182/health> in a browser. It should show
  `"status": "healthy"` and `"server": "Fusion-Essentials MCP Server"`.

## Removing it

Remove the extension in Claude Desktop (Settings › Extensions). In Fusion, stop Fusion-Essentials
in the Add-Ins dialog and untick Run on Startup, then delete its folder. The add-in's settings
are in `~/Library/Application Support/GTF_Fusion-Essentials`, and the extension's cache and backups
are in `~/Library/Application Support/Fusion MCP Bridge` and `~/Library/Caches/Fusion MCP Bridge`.

## Development

```bash
node --test test/*.test.js        # bridge, settings and installer helpers
scripts/pack_mcpb.sh              # builds build/fusion-essentials.mcpb
```

The bridge has no dependencies: `bridge/server/bridge.js` is the whole of it. One test runs it
against the real Fusion-Essentials server code (its `mcp_server.py`, outside Fusion, through its
own test harness). It needs a checkout of Fusion-Essentials and a Python with pytest:

```bash
FUSION_ESSENTIALS_DIR=../Fusion-Essentials FUSION_ESSENTIALS_PYTHON=python3 node --test test/*.test.js
```
