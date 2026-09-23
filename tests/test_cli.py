from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mesh_radio_manager.cli import main
from mesh_radio_manager.errors import ManagerError


class CliTests(unittest.TestCase):
    def test_advanced_configuration_rejects_lora_override(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings = Path(directory) / "bad.yaml"
            settings.write_text("Lora:\n  IRQ: 1\n", encoding="utf-8")
            result = main(["meshtastic", "configure", "--advanced-file", str(settings)])
            self.assertEqual(result, 2)

    def test_package_install_installs_guard_first(self) -> None:
        calls: list[str] = []
        with patch("mesh_radio_manager.cli.install_integration", side_effect=lambda **_: calls.append("guard")), patch(
            "mesh_radio_manager.cli.install_package", side_effect=lambda channel: calls.append(channel) or {"installed": "x"}
        ), patch("mesh_radio_manager.cli.set_meshtastic_channel", side_effect=lambda channel: calls.append(f"stored:{channel}")):
            self.assertEqual(main(["meshtastic", "install", "--channel", "alpha"]), 0)
        self.assertEqual(calls, ["guard", "alpha", "stored:alpha"])


if __name__ == "__main__":
    unittest.main()
