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
        self.assertNotIn("git clone https://github.com/openhop-dev", script)


if __name__ == "__main__":
    unittest.main()
