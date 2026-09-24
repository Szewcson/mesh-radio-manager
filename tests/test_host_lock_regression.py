from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ProxmoxInstallerHostLockRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = (
            ROOT / "scripts" / "proxmox-install.sh"
        ).read_text(encoding="utf-8")

    def test_installer_does_not_reenter_host_panel_for_usb_handoff(self):
        self.assertNotIn(
            '/usr/local/sbin/mesh-radio-pve --ctid "$ctid" --bootstrap-usb',
            self.script,
        )
        self.assertNotIn(
            '/usr/local/sbin/mesh-radio-pve --ctid "$ctid" --secure-usb',
            self.script,
        )

    def test_installer_calls_usb_helper_directly(self):
        self.assertIn(
            'bash "$script_dir/proxmox-usb.sh" bootstrap --ctid "$ctid"',
            self.script,
        )
        self.assertIn(
            'bash "$script_dir/proxmox-usb.sh" secure --ctid "$ctid"',
            self.script,
        )


if __name__ == "__main__":
    unittest.main()
