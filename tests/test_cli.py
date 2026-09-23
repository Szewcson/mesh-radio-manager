from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import subprocess
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

    def test_normal_update_runs_combined_manager_and_meshtastic_path(self) -> None:
        with patch(
            "mesh_radio_manager.cli.subprocess.run", return_value=subprocess.CompletedProcess([], 0)
        ) as runner:
            self.assertEqual(main(["update"]), 0)
        self.assertEqual(
            runner.call_args.args[0],
            ["/opt/mesh-radio-manager/update.sh"],
        )

    def test_update_script_uses_the_official_openhop_updater_without_copying_it(self) -> None:
        script = (Path(__file__).parents[1] / "update.sh").read_text(encoding="utf-8")
        self.assertIn("meshtastic upgrade --yes", script)
        self.assertIn("mesh-radio meshtastic status", script)
        self.assertIn('"$openhop_updater" upgrade', script)
        self.assertIn("/root/openhop-repeater/manage.sh", script)
        self.assertIn("git clone --depth 1", script)
        self.assertIn("Szewcson/mesh-radio-manager.git", script)
        self.assertNotIn("openhop-update", script)


if __name__ == "__main__":
    unittest.main()
