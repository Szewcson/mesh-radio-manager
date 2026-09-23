from __future__ import annotations

from pathlib import Path
import unittest


class ProxmoxHelperTests(unittest.TestCase):
    def test_host_helper_retrieves_official_openhop_and_installs_manager_via_pct(self) -> None:
        script = (Path(__file__).parents[1] / "scripts/proxmox-install.sh").read_text(encoding="utf-8")
        self.assertIn("openhop-dev/openhop_repeater/main/scripts/proxmox-install.sh", script)
        self.assertIn("Szewcson/mesh-radio-manager/main/install.sh", script)
        self.assertIn('pct exec "$ctid"', script)
        self.assertIn("--ctid CTID", script)
        self.assertIn('lxc.cgroup2.devices.allow: c 189:* rwm', script)
        self.assertIn('lxc.mount.entry: /dev/bus/usb', script)
        self.assertIn('ATTR{idVendor}=="1a86"', script)
        self.assertIn("unprivileged", script)
        self.assertIn("proxmox-manage.sh", script)
        self.assertIn("gnupg", script)
        self.assertNotIn("git clone https://github.com/openhop-dev", script)

    def test_operator_helpers_are_installed_and_removed_with_the_manager(self) -> None:
        root = Path(__file__).parents[1]
        install = (root / "install.sh").read_text(encoding="utf-8")
        uninstall = (root / "uninstall.sh").read_text(encoding="utf-8")
        panel = (root / "scripts/proxmox-manage.sh").read_text(encoding="utf-8")
        self.assertIn("mesh-radio-menu", install)
        self.assertIn("mesh-radio-manager-profile.sh", install)
        self.assertIn("mesh-radio-menu", uninstall)
        self.assertIn("Update everything", panel)

    def test_meshtastic_install_prerequisite_is_included(self) -> None:
        root = Path(__file__).parents[1]
        install = (root / "install.sh").read_text(encoding="utf-8")
        self.assertIn("apt-get install -y gnupg", install)


if __name__ == "__main__":
    unittest.main()
