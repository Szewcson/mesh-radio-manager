from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import nullcontext
from unittest.mock import patch

import yaml

from mesh_radio_manager.errors import ManagerError
from mesh_radio_manager.integration import OPENHOP_DROPIN_TEXT, upstream_unit_supported
from mesh_radio_manager.meshtastic import (
    MESHTASTIC_WEB_UI_DEFAULT_PORT,
    apply_web_ui_settings,
    backup_config,
    installed as meshtastic_installed,
    restore_config,
    validate_web_ui_enable,
    web_ui_settings,
)
from mesh_radio_manager.openhop import installed as openhop_installed, metadata, prepare_persistent_config
from mesh_radio_manager.usb import UsbDevice
from mesh_radio_manager.services import action


class ExternalServiceTests(unittest.TestCase):
    def test_openhop_absent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertFalse(openhop_installed(root / "checkout", root / "config.yaml"))

    def test_openhop_installed_clean_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout = root / "openhop"
            checkout.mkdir()
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            (checkout / "README").write_text("upstream\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(checkout), "add", "README"], check=True)
            subprocess.run(
                ["git", "-C", str(checkout), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial"],
                check=True,
            )
            config = root / "config.yaml"
            config.write_text("{}\n", encoding="utf-8")
            self.assertTrue(openhop_installed(checkout, config))
            self.assertTrue(metadata(checkout, config)["clean"])

    def test_openhop_selector_update_keeps_dashboard_configuration_persistent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "openhop.yaml"
            manager = root / "manager.yaml"
            source.write_text(
                yaml.safe_dump({"repeater": {"security": {"admin_password": "changed", "api_token": "saved"}}}),
                encoding="utf-8",
            )
            manager.write_text(
                yaml.safe_dump(
                    {
                        "version": 1,
                        "assignments": {
                            "openhop": {
                                "identity": {"vid": "1a86", "pid": "5512", "port_path": "pci/ports/2"},
                                "profile": "pinedio",
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            device = UsbDevice(0x1A86, 0x5512, 3, 4, "3-2", "pci/ports/2", None, None, None)
            with patch("mesh_radio_manager.openhop.configuration_lock", return_value=nullcontext()), patch(
                "mesh_radio_manager.openhop.enumerate_devices", return_value=[device]
            ):
                self.assertEqual(prepare_persistent_config(source=source, manager_config=manager), source)
            saved = yaml.safe_load(source.read_text(encoding="utf-8"))
            self.assertEqual(saved["repeater"]["security"], {"admin_password": "changed", "api_token": "saved"})
            self.assertEqual(saved["ch341"]["address"], 4)

    def test_manager_files_do_not_dirty_upstream_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout = root / "openhop"
            checkout.mkdir()
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            (checkout / "README").write_text("upstream\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(checkout), "add", "README"], check=True)
            subprocess.run(
                ["git", "-C", str(checkout), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial"],
                check=True,
            )
            manager_dropin = root / "etc/systemd/system/openhop-repeater.service.d/20-mesh-radio-manager.conf"
            manager_dropin.parent.mkdir(parents=True)
            manager_dropin.write_text("[Service]\n", encoding="utf-8")
            self.assertEqual(subprocess.run(["git", "-C", str(checkout), "status", "--short"], text=True, capture_output=True, check=True).stdout, "")

    def test_meshtastic_absent_and_present(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "meshtasticd"
            self.assertFalse(meshtastic_installed(binary))
            binary.write_text("#!/bin/sh\n", encoding="utf-8")
            binary.chmod(0o755)
            self.assertTrue(meshtastic_installed(binary))

    def test_meshtastic_web_ui_uses_a_distinct_default_port_and_rejects_ui_collisions(self) -> None:
        data = {"meshtastic": {"web_ui": {"enabled": True, "port": MESHTASTIC_WEB_UI_DEFAULT_PORT}}, "web": {"port": 8001}}
        settings = web_ui_settings(data)
        self.assertEqual(settings, {"enabled": True, "port": 9443})
        effective = apply_web_ui_settings({"Lora": {}}, settings)
        self.assertEqual(effective["Webserver"]["Port"], 9443)
        self.assertIn("SSLKey", effective["Webserver"])
        with self.assertRaisesRegex(ManagerError, "openHop web UI"):
            validate_web_ui_enable(data, 8000, "")
        with self.assertRaisesRegex(ManagerError, "Meshtastic TCP API"):
            validate_web_ui_enable(data, 4403, "")

    def test_meshtastic_web_ui_setting_can_be_saved(self) -> None:
        with patch("mesh_radio_manager.meshtastic.load", return_value={"meshtastic": {}, "assignments": {}}), patch(
            "mesh_radio_manager.meshtastic.configuration_lock", return_value=nullcontext()
        ), patch("mesh_radio_manager.meshtastic.validate_web_ui_enable"), patch(
            "mesh_radio_manager.meshtastic.save"
        ) as save_config:
            from mesh_radio_manager.meshtastic import set_web_ui

            previous, selected = set_web_ui(True, port=9443)
        self.assertEqual(previous, {"enabled": False, "port": 9443})
        self.assertEqual(selected, {"enabled": True, "port": 9443})
        self.assertTrue(save_config.called)

    def test_backup_restore(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "config.yaml"
            source.write_text("original\n", encoding="utf-8")
            backup = backup_config(source, root / "backups")
            self.assertIsNotNone(backup)
            source.write_text("changed\n", encoding="utf-8")
            restore_config(backup, source)  # type: ignore[arg-type]
            self.assertEqual(source.read_text(encoding="utf-8"), "original\n")

    def test_unit_contract_and_service_start_validation(self) -> None:
        self.assertTrue(upstream_unit_supported("ExecStart=/opt/openhop_repeater/venv/bin/python -m repeater.main"))
        self.assertFalse(upstream_unit_supported("ExecStart=/usr/bin/other"))
        self.assertIn("ExecStartPre=+/usr/local/bin/mesh-radio internal prepare-openhop", OPENHOP_DROPIN_TEXT)
        self.assertNotIn("ExecStart=", OPENHOP_DROPIN_TEXT)
        self.assertNotIn("/run/mesh-radio-manager/openhop-config.yaml", OPENHOP_DROPIN_TEXT)
        success = subprocess.CompletedProcess([], 0, "", "")
        with patch("mesh_radio_manager.services._run", return_value=success):
            action("openhop-repeater.service", "start")
        failed = subprocess.CompletedProcess([], 1, "", "failure")
        with patch("mesh_radio_manager.services._run", return_value=failed):
            with self.assertRaisesRegex(ManagerError, "failure"):
                action("openhop-repeater.service", "start")

    def test_uninstall_script_targets_manager_only_and_restarts_openhop(self) -> None:
        script = (Path(__file__).parents[1] / "uninstall.sh").read_text(encoding="utf-8")
        self.assertIn("/opt/mesh-radio-manager", script)
        self.assertIn("/etc/mesh-radio-manager", script)
        self.assertIn("systemctl restart openhop-repeater.service", script)
        self.assertNotIn("rm -rf /root/openhop-repeater", script)
        self.assertNotIn("rm -rf /opt/openhop_repeater", script)


if __name__ == "__main__":
    unittest.main()
