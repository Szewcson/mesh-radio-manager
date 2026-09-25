from __future__ import annotations

import subprocess
import unittest
from unittest.mock import patch

from mesh_radio_manager.errors import ManagerError
from mesh_radio_manager.integration import enable_meshtasticd, install
from mesh_radio_manager.meshtastic import MESHTASTIC_UNIT


class IntegrationTests(unittest.TestCase):
    def test_install_writes_integration_and_reloads_without_enabling_meshtastic(self) -> None:
        calls: list[tuple[str, ...]] = []

        def systemctl(*args: str, **_kwargs: object) -> str:
            calls.append(args)
            if args == ("cat", "openhop-repeater.service"):
                return "ExecStart=/opt/openhop_repeater/venv/bin/python -m repeater.main"
            return ""

        with patch("mesh_radio_manager.integration._systemctl", side_effect=systemctl), patch(
            "mesh_radio_manager.integration._atomic_write"
        ):
            install()

        self.assertEqual(calls, [("cat", "openhop-repeater.service"), ("daemon-reload",)])

    def test_enable_meshtasticd_enables_for_boot_without_starting(self) -> None:
        with patch("mesh_radio_manager.integration._systemctl") as systemctl:
            enable_meshtasticd()

        systemctl.assert_called_once_with("enable", MESHTASTIC_UNIT)
        command = systemctl.call_args.args
        self.assertNotIn("start", command)
        self.assertNotIn("--now", command)

    def test_enable_meshtasticd_failure_is_reported(self) -> None:
        failed = subprocess.CompletedProcess([], 1, "", "unit not found")
        with patch("mesh_radio_manager.integration.subprocess.run", return_value=failed):
            with self.assertRaisesRegex(ManagerError, "unit not found"):
                enable_meshtasticd()


if __name__ == "__main__":
    unittest.main()
