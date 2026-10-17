"""Check that an installed Fusion-Essentials add-in will start its MCP server.

Imports the installed add-in's own commands package (which runs its real settings code against
the settings file, as loading the add-in in Fusion does) with the add-in's mocked adsk layer, and
checks that the MCP Server feature is switched on. Run with a Python that has pytest:

    python check_addin_settings.py <installed Fusion-Essentials folder> <home folder>
"""

import importlib
import os
import platform
import sys
import types

addin, home = sys.argv[1], sys.argv[2]
os.environ["HOME"] = home
platform.system = lambda: "Darwin"  # the add-in picks its settings folder by platform
sys.path.insert(0, os.path.join(addin, "tests"))

from conftest import install_mock_adsk  # noqa: E402  (needs the path above)

install_mock_adsk()
package = types.ModuleType("installed_addin")
package.__path__ = [addin]
sys.modules["installed_addin"] = package

commands = importlib.import_module("installed_addin.commands")
shared_state = sys.modules["installed_addin.shared_state"]
feature = commands.mcpServer.CMD_ID.replace(" ", "_")
enabled = shared_state.load_settings("FEATURE_ENABLEMENT")[feature]["default"]
print(f"{shared_state.SETTINGS_FILE}: {feature} = {enabled}")
sys.exit(0 if enabled is True else 1)
