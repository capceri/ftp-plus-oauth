"""Serve the real Fusion-Essentials MCP transport outside Fusion, for the bridge's integration test.

Loads the add-in's own commands/mcpServer/server/mcp_server.py through the repository's test
harness (tests/conftest.py, which mocks the adsk API), registers two small tools built with the
add-in's own Item/Tool classes, and serves on 127.0.0.1:<port>.

    python fusion_essentials_server.py <fusion-essentials checkout> <port>

Prints "ready <port>" once serving. Each "restart" line on stdin stops the server and starts a
new one on the same port, as reloading the add-in does; "stop" stops it until the next
"restart". Exits when stdin closes. Progress goes to stdout as "log: ..." lines, and a server
that cannot start prints "failed: ..." before exiting, so the test can say what went wrong.
"""

import os
import sys
import time
import traceback

repo, port = sys.argv[1], int(sys.argv[2])
sys.path.insert(0, os.path.join(repo, "tests"))

from conftest import load_mcp_server  # noqa: E402  (needs the path above)

mcp = load_mcp_server()
primitives = sys.modules["mcpServer.mcp_primitives"]
# The harness stubs Fusion's logger to do nothing; show the add-in's errors instead.
mcp.futil.handle_error = lambda *args, **kwargs: traceback.print_exc()
# Before binding, the add-in connects to its port to check nobody is listening there. The test
# harness forbids outgoing connections, so bind the plain way (still with SO_REUSEADDR); the
# HTTP handling is the add-in's own.
mcp.ThreadedHTTPServer.server_bind = mcp.HTTPServer.server_bind


def orient():
    return {"content": [{"type": "text", "text": "Untitled design is open"}], "isError": False}


def extrude(distance: float = 1.0):
    return {"content": [{"type": "text", "text": f"extruded {distance} cm"}], "isError": False}


def items():
    read = primitives.Tool(name="workspace_orient", description="What is open in Fusion.",
                           input_schema={"type": "object", "properties": {}})
    write = primitives.Tool(name="model_extrude", description="Extrude a profile.",
                            input_schema={"type": "object",
                                          "properties": {"distance": {"type": "number"}}})
    return [
        primitives.Item.create_tool_item(tool=read, handler=orient, write="read",
                                         run_on_main_thread=False),
        primitives.Item.create_tool_item(tool=write, handler=extrude, write="write",
                                         run_on_main_thread=False),
    ]


running = None


def say(text):
    print(text, flush=True)


def start():
    """Start the server, giving the OS up to 20 s to free the port after the last one."""
    global running
    deadline = time.monotonic() + 20
    attempt = 0
    while True:
        attempt += 1
        result = mcp.start_server("127.0.0.1", port, items=items(), job_store=object())
        if result.get("status") == mcp.START_OK:
            running = result
            say(f"ready {port} (attempt {attempt})")
            return
        say(f"log: start attempt {attempt} on port {port}: {result}")
        if time.monotonic() > deadline:
            say(f"failed: could not start the Fusion-Essentials server on port {port}: {result}")
            sys.exit(1)
        time.sleep(0.5)


def stop():
    global running
    if running:
        began = time.monotonic()
        stopped = mcp.stop_server(running["http_server"], running["thread"])
        say(f"log: stop_server returned {stopped} after {time.monotonic() - began:.1f} s")
        running = None


try:
    start()
    for line in sys.stdin:
        command = line.strip()
        if command == "restart":
            stop()
            start()
        elif command == "stop":
            stop()
            say("stopped")
    stop()
except Exception:
    say("failed: " + traceback.format_exc().replace("\n", " | "))
    sys.exit(1)
