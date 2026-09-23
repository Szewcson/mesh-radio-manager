from __future__ import annotations

from pathlib import Path
import unittest


class ProxmoxHelperTests(unittest.TestCase):
    def test_host_helper_reuses_official_openhop_and_installs_verified_manager_package(self) -> None:
        script = (Path(__file__).parents[1] / "scripts/proxmox-install.sh").read_text(encoding="utf-8")
        self.assertIn("openhop-dev/openhop_repeater/main/scripts/proxmox-install.sh", script)
        self.assertIn('pct exec "$ctid"', script)
        self.assertIn('pct push "$ctid" "$manager_package"', script)
        self.assertIn("--manager-package PATH", script)
        self.assertIn("--advanced", script)
        self.assertIn("--unattended", script)
        self.assertIn("--ctid CTID", script)
        self.assertIn("pveversion", script)
        self.assertIn("Proxmox VE 8.4 or newer is required", script)
        self.assertIn("proxmox-host-lifecycle.lock", script)
        self.assertIn("preflight_lxc", script)
        self.assertIn("mesh-radio-manager", script)
        self.assertIn('lxc.cgroup2.devices.allow: c 189:* rwm', script)
        self.assertIn('lxc.mount.entry: /dev/bus/usb', script)
        self.assertIn('ATTR{idVendor}=="1a86"', script)
        self.assertIn("unprivileged", script)
        self.assertIn("proxmox-manage.sh", script)
        self.assertIn("gnupg", script)
        self.assertIn("--apt-source-manifest FILE", script)
        self.assertIn("mesh-radio-apt-repository", script)
        self.assertIn("validate_apt_source_manifest", script)
        self.assertNotIn("mesh-radio-manager/main/install.sh", script)
        self.assertNotIn("manager_command=", script)
        self.assertNotIn("git clone https://github.com/openhop-dev", script)

    def test_operator_helpers_are_installed_and_removed_with_the_manager(self) -> None:
        root = Path(__file__).parents[1]
        install = (root / "install.sh").read_text(encoding="utf-8")
        uninstall = (root / "uninstall.sh").read_text(encoding="utf-8")
        panel = (root / "scripts/proxmox-manage.sh").read_text(encoding="utf-8")
        self.assertIn("mesh-radio-menu", install)
        self.assertIn("mesh-radio-manager-profile.sh", install)
        self.assertIn("mesh-radio-menu", uninstall)
        self.assertIn("compat_launcher=/usr/bin/mesh-radio", uninstall)
        self.assertIn("Update everything", panel)
        self.assertIn("--all --update --yes", panel)
        self.assertIn("vzdump", panel)
        self.assertIn("--dry-run", panel)
        self.assertIn("--doctor", panel)
        self.assertIn("--prune", panel)
        self.assertIn("restore_ct", panel)
        self.assertIn("restore_initial_state", panel)
        self.assertIn("proxmox-host-lifecycle.lock", panel)
        self.assertIn("SKIPPED_EXIT=75", panel)
        self.assertIn("Template LXC", panel)
        self.assertIn("refusing a forced rollback", panel)
        self.assertIn("Could not shut down LXC", panel)
        self.assertIn("refusing an incomplete managed-LXC scan", panel)
        self.assertIn("validate_update_target", panel)
        self.assertIn("else\n    check_status=$?\n  fi", panel)

    def test_meshtastic_install_prerequisite_is_included(self) -> None:
        root = Path(__file__).parents[1]
        install = (root / "install.sh").read_text(encoding="utf-8")
        self.assertIn("apt-get install -y gnupg", install)

    def test_installers_validate_the_manager_launcher(self) -> None:
        root = Path(__file__).parents[1]
        install = (root / "install.sh").read_text(encoding="utf-8")
        helper = (root / "scripts/proxmox-install.sh").read_text(encoding="utf-8")
        self.assertIn('mktemp -d "$manager_root/releases/.stage.', install)
        self.assertIn('replace_link "releases/$release_id" "$current_link"', install)
        self.assertIn('"$manager_root/current/venv/bin/mesh-radio"', install)
        self.assertIn('"$compat_launcher" --version', install)
        self.assertIn("legacy_launcher=/usr/bin/mesh-radio", install)
        self.assertIn('pct exec "$ctid" -- /usr/bin/mesh-radio --version', helper)

    def test_manager_only_update_uses_the_signed_debian_package_path(self) -> None:
        root = Path(__file__).parents[1]
        script = (root / "manager-update.sh").read_text(encoding="utf-8")
        install = (root / "install.sh").read_text(encoding="utf-8")
        self.assertIn("dpkg-query", script)
        self.assertIn("apt-get install --only-upgrade --yes", script)
        self.assertIn("flock -n 3", script)
        self.assertIn("package-lifecycle.lock", script)
        self.assertIn("mutable branch", script)
        self.assertNotIn("curl |", script)
        self.assertNotIn("git -C", script)
        self.assertIn("manager-update.sh", install)

    def test_debian_package_and_ci_are_present(self) -> None:
        root = Path(__file__).parents[1]
        control = (root / "debian/control").read_text(encoding="utf-8")
        postinst = (root / "debian/mesh-radio-manager.postinst").read_text(encoding="utf-8")
        ci = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        release = (root / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("Package: mesh-radio-manager", control)
        self.assertIn("install-integration", postinst)
        self.assertIn("dpkg-buildpackage", ci)
        self.assertIn("build-essential", ci)
        self.assertIn("actions/checkout@v7", ci)
        self.assertIn("actions/setup-python@v7", ci)
        self.assertIn("actions/attest@v4", release)
        apt_setup = (root / "scripts/configure-apt-repository.sh").read_text(encoding="utf-8")
        apt_publish = (root / "scripts/publish-apt-repository.sh").read_text(encoding="utf-8")
        self.assertIn("--show-keys --with-colons", apt_setup)
        self.assertIn("Signed-By:", apt_setup)
        self.assertIn("reprepro", apt_publish)
        self.assertIn("--manifest RELEASE_APT_SOURCE_ENV", apt_setup)
        self.assertIn("flock -n 9", apt_setup)
        self.assertIn("package-lifecycle.lock", apt_setup)
        self.assertIn("--max-filesize 1048576", apt_setup)
        self.assertIn("actions/upload-pages-artifact@v4", release)
        self.assertIn("actions/deploy-pages@v4", release)
        self.assertIn("APT_GPG_PRIVATE_KEY_BASE64", release)
        self.assertIn("Remove temporary APT archive key", release)
        self.assertIn('gpgconf --homedir "$key_home" --kill all', release)
        self.assertIn("Install signing prerequisites", release)
        self.assertIn("build-essential", release)
        self.assertIn("actions/checkout@v7", release)
        self.assertIn("actions/setup-python@v7", release)
        self.assertIn('mktemp -d "${RUNNER_TEMP:?}/mesh-radio-manager-gpg.XXXXXX"', release)
        documentation = (root / "docs/apt-repository.md").read_text(encoding="utf-8")
        self.assertIn("external secret manager", documentation)
        self.assertNotIn("KeePassXC", documentation)
        self.assertNotIn("quick-generate-key", documentation)


if __name__ == "__main__":
    unittest.main()
