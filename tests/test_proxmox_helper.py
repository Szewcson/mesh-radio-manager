from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import tomllib
import unittest


class ProxmoxHelperTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("reprepro"), "reprepro is not installed")
    def test_reprepro_accepts_release_architectures(self) -> None:
        distribution = """\
Origin: Mesh Radio Manager
Label: Mesh Radio Manager
Codename: stable
Suite: stable
Architectures: amd64 arm64 source
Components: main
Description: Mesh Radio Manager signed package archive
"""
        with tempfile.TemporaryDirectory(prefix="mesh-radio-manager-reprepro-") as directory:
            configuration = Path(directory) / "conf"
            configuration.mkdir()
            (configuration / "distributions").write_text(distribution, encoding="utf-8")
            result = subprocess.run(
                ["reprepro", "--basedir", directory, "export", "stable"],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_host_helper_reuses_official_openhop_and_installs_verified_manager_package(self) -> None:
        script = (Path(__file__).parents[1] / "scripts/proxmox-install.sh").read_text(encoding="utf-8")
        self.assertIn("openhop-dev/openhop_repeater/main/scripts/proxmox-install.sh", script)
        self.assertIn("MANAGER_DEFAULT_HOSTNAME_LINE='CT_HOSTNAME=\"mesh-radio-manager\"'", script)
        self.assertIn('grep -Fxc "$OPENHOP_DEFAULT_HOSTNAME_LINE" "$openhop_script"', script)
        self.assertIn('sed -i "s|^${OPENHOP_DEFAULT_HOSTNAME_LINE}$|${MANAGER_DEFAULT_HOSTNAME_LINE}|"', script)
        self.assertIn("Refusing to modify its prompts", script)
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
        self.assertIn('proxmox-usb.sh', script)
        self.assertIn('--secure-usb', script)
        self.assertIn('--bootstrap-usb', script)
        self.assertIn("--unprivileged", script)
        self.assertIn("patch_upstream_for_unprivileged_lxc", script)
        self.assertIn("OPENHOP_PRIVILEGED_PATTERN", script)
        self.assertIn("mode_context_count", script)
        self.assertIn("OPENHOP_CH341_PROMPT", script)
        self.assertIn('index($0, "# ── USB passthrough") == 1', script)
        self.assertIn("USB compatibility block changed", script)
        self.assertIn("select_host_radio", script)
        self.assertIn("configure_selected_radios_in_lxc", script)
        self.assertIn("--manual-radio-configuration", script)
        self.assertIn("--bootstrap-usb", script)
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
        self.assertIn("--usb-devices", panel)
        self.assertIn("--secure-usb", panel)
        self.assertIn("--bootstrap-usb", panel)
        self.assertIn("--refresh-usb", panel)
        self.assertIn("proxmox-usb.sh", panel)

    def test_device_scoped_usb_helper_replaces_wildcard_in_simulated_pve(self) -> None:
        root = Path(__file__).parents[1]
        helper = root / "scripts/proxmox-usb.sh"
        with tempfile.TemporaryDirectory(prefix="mesh-radio-manager-pve-usb-") as directory:
            sandbox = Path(directory)
            sys_usb = sandbox / "sys/bus/usb/devices"
            dev_root = sandbox / "dev"
            udev_dir = sandbox / "udev"
            pve_dir = sandbox / "pve/lxc"
            state_dir = sandbox / "state"
            bin_dir = sandbox / "bin"
            sys_usb.mkdir(parents=True)
            (dev_root / "bus/usb/003").mkdir(parents=True)
            pve_dir.mkdir(parents=True)
            bin_dir.mkdir()

            radios = (("3-2", "3", "3", "", "2"), ("3-1", "2", "3", "12345678", "1"))
            for path, address, bus, serial, port in radios:
                device = sandbox / f"devices/pci0000:00/0000:00:10.0/usb{bus}/{path}"
                device.mkdir(parents=True)
                (device / "idVendor").write_text("1a86\n", encoding="utf-8")
                (device / "idProduct").write_text("5512\n", encoding="utf-8")
                (device / "busnum").write_text(f"{bus}\n", encoding="utf-8")
                (device / "devnum").write_text(f"{address}\n", encoding="utf-8")
                if serial:
                    (device / "serial").write_text(f"{serial}\n", encoding="utf-8")
                (sys_usb / path).symlink_to(device)
                (dev_root / f"bus/usb/003/{int(address):03d}").symlink_to("/dev/null")

            config = pve_dir / "103.conf"
            config.write_text(
                "unprivileged: 0\n"
                "tags: mesh-radio-manager\n"
                "lxc.cgroup2.devices.allow: c 189:* rwm\n"
                "lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0\n",
                encoding="utf-8",
            )
            pve_state = sandbox / "pve-state"
            pve_state.write_text("running\n", encoding="utf-8")
            (bin_dir / "getent").write_text("#!/bin/sh\necho 'plugdev:x:46:'\n", encoding="utf-8")
            (bin_dir / "getent").chmod(0o755)
            (bin_dir / "udevadm").write_text(
                textwrap.dedent(
                    """\
                    #!/bin/sh
                    case "$1" in
                      info)
                        case "$4" in
                          */002) echo 'ID_PATH=pci-0000:00:10.0-usb-0:1' ;;
                          */003) echo 'ID_PATH=pci-0000:00:10.0-usb-0:2' ;;
                        esac
                        ;;
                      trigger)
                        mkdir -p "$MESH_RADIO_DEV_ROOT/mesh-radio-manager"
                        ln -sfn "$MESH_RADIO_DEV_ROOT/bus/usb/003/003" "$MESH_RADIO_DEV_ROOT/mesh-radio-manager/ct103-openhop"
                        ln -sfn "$MESH_RADIO_DEV_ROOT/bus/usb/003/002" "$MESH_RADIO_DEV_ROOT/mesh-radio-manager/ct103-meshtastic"
                        ;;
                    esac
                    """
                ),
                encoding="utf-8",
            )
            (bin_dir / "udevadm").chmod(0o755)
            (bin_dir / "pct").write_text(
                textwrap.dedent(
                    """\
                    #!/bin/sh
                    config="$MESH_RADIO_PVE_LXC_DIR/103.conf"
                    case "$1" in
                      status) printf 'status: %s\\n' "$(cat "$MESH_RADIO_TEST_PVE_STATE")" ;;
                      config) cat "$config" ;;
                      set) printf '%s: %s\\n' "${3#--}" "$4" >>"$config" ;;
                      shutdown) echo stopped >"$MESH_RADIO_TEST_PVE_STATE" ;;
                      start) echo running >"$MESH_RADIO_TEST_PVE_STATE" ;;
                      exec)
                        shift 3
                        case "$1" in
                          getent) echo 'plugdev:x:46:' ;;
                          true|/usr/bin/mesh-radio) exit 0 ;;
                        esac
                        ;;
                    esac
                    """
                ),
                encoding="utf-8",
            )
            (bin_dir / "pct").chmod(0o755)
            environment = {
                "PATH": f"{bin_dir}:{Path('/usr/bin')}:{Path('/bin')}",
                "MESH_RADIO_SYS_USB_ROOT": str(sys_usb),
                "MESH_RADIO_DEV_ROOT": str(dev_root),
                "MESH_RADIO_UDEV_DIR": str(udev_dir),
                "MESH_RADIO_PVE_LXC_DIR": str(pve_dir),
                "MESH_RADIO_PVE_USB_STATE_DIR": str(state_dir),
                "MESH_RADIO_PVE_USB_LOCK_DIR": str(sandbox / "lock"),
                "MESH_RADIO_PCT": "pct",
                "MESH_RADIO_UDEVADM": "udevadm",
                "MESH_RADIO_TEST_PVE_STATE": str(pve_state),
                "MESH_RADIO_TEST_MODE": "1",
            }
            result = subprocess.run(
                [
                    "bash",
                    str(helper),
                    "secure",
                    "--ctid",
                    "103",
                    "--openhop-selector",
                    "port:pci0000:00/0000:00:10.0/ports/2",
                    "--meshtastic-selector",
                    "serial:12345678",
                    "--yes",
                ],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            hardened = config.read_text(encoding="utf-8")
            self.assertNotIn("c 189:* rwm", hardened)
            self.assertIn(f"dev0: {dev_root}/mesh-radio-manager/ct103-openhop,uid=0,gid=0,mode=0600", hardened)
            self.assertIn(f"dev1: {dev_root}/mesh-radio-manager/ct103-meshtastic,uid=0,gid=0,mode=0600", hardened)
            rules = (udev_dir / "99-mesh-radio-manager-103.rules").read_text(encoding="utf-8")
            self.assertIn('ATTR{serial}=="12345678"', rules)
            self.assertIn('ENV{ID_PATH}=="pci-0000:00:10.0-usb-0:2"', rules)
            self.assertTrue((state_dir / "103.conf").is_file())

            reconfigured = subprocess.run(
                [
                    "bash",
                    str(helper),
                    "secure",
                    "--ctid",
                    "103",
                    "--openhop-selector",
                    "port:pci0000:00/0000:00:10.0/ports/2",
                    "--meshtastic-selector",
                    "serial:12345678",
                    "--yes",
                ],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(reconfigured.returncode, 0, reconfigured.stdout + reconfigured.stderr)

            refreshed = subprocess.run(
                ["bash", str(helper), "refresh", "--ctid", "103", "--yes"],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(refreshed.returncode, 0, refreshed.stderr)

            # USB descriptors are device-controlled.  A port-selected radio
            # with rule syntax in its serial must not be eligible for a udev
            # rule, even though the serial is not the selected identity.
            (sandbox / "devices/pci0000:00/0000:00:10.0/usb3/3-2/serial").write_text(
                'unsafe", MODE="0666"\n', encoding="utf-8"
            )
            unsafe_metadata = subprocess.run(
                [
                    "bash",
                    str(helper),
                    "secure",
                    "--ctid",
                    "103",
                    "--openhop-selector",
                    "port:pci0000:00/0000:00:10.0/ports/2",
                    "--meshtastic-selector",
                    "serial:12345678",
                    "--yes",
                ],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertNotEqual(unsafe_metadata.returncode, 0)
            self.assertNotIn(
                'unsafe", MODE="0666"',
                (udev_dir / "99-mesh-radio-manager-103.rules").read_text(encoding="utf-8"),
            )
            (sandbox / "devices/pci0000:00/0000:00:10.0/usb3/3-2/serial").unlink()

            # Rule token order is not an access-control boundary.  Detect a
            # broad rule even when its MODE predicate precedes VID/PID.
            (udev_dir / "unmanaged.rules").write_text(
                'MODE="0666", ATTR{idProduct}=="5512", ATTR{idVendor}=="1a86"\n', encoding="utf-8"
            )
            status = subprocess.run(
                ["bash", str(helper), "status", "--ctid", "103"],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertNotEqual(status.returncode, 0)
            self.assertIn("Broad CH341 udev rule", status.stderr)

    def test_unprivileged_handoff_uses_shifted_plugdev_gid_without_broad_policy(self) -> None:
        root = Path(__file__).parents[1]
        helper = root / "scripts/proxmox-usb.sh"
        with tempfile.TemporaryDirectory(prefix="mesh-radio-manager-pve-unprivileged-") as directory:
            sandbox = Path(directory)
            sys_usb = sandbox / "sys/bus/usb/devices"
            dev_root = sandbox / "dev"
            udev_dir = sandbox / "udev"
            pve_dir = sandbox / "pve/lxc"
            state_dir = sandbox / "state"
            bin_dir = sandbox / "bin"
            sys_usb.mkdir(parents=True)
            (dev_root / "bus/usb/003").mkdir(parents=True)
            pve_dir.mkdir(parents=True)
            bin_dir.mkdir()

            for path, address, serial in (("3-2", "3", ""), ("3-1", "2", "12345678")):
                device = sandbox / f"devices/pci0000:00/0000:00:10.0/usb3/{path}"
                device.mkdir(parents=True)
                (device / "idVendor").write_text("1a86\n", encoding="utf-8")
                (device / "idProduct").write_text("5512\n", encoding="utf-8")
                (device / "busnum").write_text("3\n", encoding="utf-8")
                (device / "devnum").write_text(f"{address}\n", encoding="utf-8")
                if serial:
                    (device / "serial").write_text(f"{serial}\n", encoding="utf-8")
                (sys_usb / path).symlink_to(device)
                (dev_root / f"bus/usb/003/{int(address):03d}").symlink_to("/dev/null")

            config = pve_dir / "104.conf"
            config.write_text(
                "unprivileged: 1\n"
                "lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0\n",
                encoding="utf-8",
            )
            pve_state = sandbox / "pve-state"
            pve_state.write_text("running\n", encoding="utf-8")
            (bin_dir / "getent").write_text("#!/bin/sh\necho 'plugdev:x:46:'\n", encoding="utf-8")
            (bin_dir / "getent").chmod(0o755)
            (bin_dir / "udevadm").write_text(
                textwrap.dedent(
                    """\
                    #!/bin/sh
                    case "$1" in
                      info)
                        case "$4" in
                          */002) echo 'ID_PATH=pci-0000:00:10.0-usb-0:1' ;;
                          */003) echo 'ID_PATH=pci-0000:00:10.0-usb-0:2' ;;
                        esac
                        ;;
                      trigger)
                        mkdir -p "$MESH_RADIO_DEV_ROOT/mesh-radio-manager"
                        ln -sfn "$MESH_RADIO_DEV_ROOT/bus/usb/003/003" "$MESH_RADIO_DEV_ROOT/mesh-radio-manager/ct104-openhop"
                        ln -sfn "$MESH_RADIO_DEV_ROOT/bus/usb/003/002" "$MESH_RADIO_DEV_ROOT/mesh-radio-manager/ct104-meshtastic"
                        ;;
                    esac
                    """
                ),
                encoding="utf-8",
            )
            (bin_dir / "udevadm").chmod(0o755)
            (bin_dir / "pct").write_text(
                textwrap.dedent(
                    """\
                    #!/bin/sh
                    config="$MESH_RADIO_PVE_LXC_DIR/104.conf"
                    case "$1" in
                      status) printf 'status: %s\\n' "$(cat "$MESH_RADIO_TEST_PVE_STATE")" ;;
                      set) printf '%s: %s\\n' "${3#--}" "$4" >>"$config" ;;
                      shutdown) echo stopped >"$MESH_RADIO_TEST_PVE_STATE" ;;
                      start) echo running >"$MESH_RADIO_TEST_PVE_STATE" ;;
                      exec)
                        shift 3
                        case "$1" in
                          getent) echo 'plugdev:x:46:' ;;
                          cat) printf '0 100000 65536\\n' ;;
                          true|/usr/bin/mesh-radio) exit 0 ;;
                        esac
                        ;;
                    esac
                    """
                ),
                encoding="utf-8",
            )
            (bin_dir / "pct").chmod(0o755)
            environment = {
                "PATH": f"{bin_dir}:{Path('/usr/bin')}:{Path('/bin')}",
                "MESH_RADIO_SYS_USB_ROOT": str(sys_usb),
                "MESH_RADIO_DEV_ROOT": str(dev_root),
                "MESH_RADIO_UDEV_DIR": str(udev_dir),
                "MESH_RADIO_PVE_LXC_DIR": str(pve_dir),
                "MESH_RADIO_PVE_USB_STATE_DIR": str(state_dir),
                "MESH_RADIO_PVE_USB_LOCK_DIR": str(sandbox / "lock"),
                "MESH_RADIO_PCT": "pct",
                "MESH_RADIO_UDEVADM": "udevadm",
                "MESH_RADIO_TEST_PVE_STATE": str(pve_state),
                "MESH_RADIO_TEST_MODE": "1",
            }
            result = subprocess.run(
                [
                    "bash",
                    str(helper),
                    "bootstrap",
                    "--ctid",
                    "104",
                    "--openhop-selector",
                    "port:pci0000:00/0000:00:10.0/ports/2",
                    "--meshtastic-selector",
                    "serial:12345678",
                    "--yes",
                ],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            hardened = config.read_text(encoding="utf-8")
            self.assertNotIn("c 189:* rwm", hardened)
            self.assertIn(f"dev0: {dev_root}/mesh-radio-manager/ct104-openhop,uid=0,gid=46,mode=0660", hardened)
            self.assertIn(f"dev1: {dev_root}/mesh-radio-manager/ct104-meshtastic,uid=0,gid=46,mode=0660", hardened)
            rules = (udev_dir / "99-mesh-radio-manager-104.rules").read_text(encoding="utf-8")
            self.assertIn('GROUP="100046", MODE="0660"', rules)
            state = (state_dir / "104.conf").read_text(encoding="utf-8")
            self.assertIn("container_mode=unprivileged", state)
            self.assertIn("pve_device_gid=46", state)
            self.assertIn("state_phase=bootstrap", state)

            finalized = subprocess.run(
                [
                    "bash",
                    str(helper),
                    "secure",
                    "--ctid",
                    "104",
                    "--openhop-selector",
                    "port:pci0000:00/0000:00:10.0/ports/2",
                    "--meshtastic-selector",
                    "serial:12345678",
                    "--yes",
                ],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(finalized.returncode, 0, finalized.stdout + finalized.stderr)
            finalized_state = (state_dir / "104.conf").read_text(encoding="utf-8")
            self.assertIn("state_phase=active", finalized_state)

            host_preflight = subprocess.run(
                ["bash", str(helper), "preflight"],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(host_preflight.returncode, 0, host_preflight.stdout + host_preflight.stderr)
            (udev_dir / "legacy-broad.rules").write_text(
                'MODE="0666", ATTR{idProduct}=="5512", ATTR{idVendor}=="1a86"\n', encoding="utf-8"
            )
            blocked_preflight = subprocess.run(
                ["bash", str(helper), "preflight"],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertNotEqual(blocked_preflight.returncode, 0)
            self.assertIn("refuses host CH341 MODE=0666", blocked_preflight.stderr)

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
        pyproject = tomllib.loads((root / "pyproject.toml").read_text(encoding="utf-8"))
        ci = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        release = (root / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("Package: mesh-radio-manager", control)
        self.assertEqual(pyproject["project"]["license"], {"text": "MIT"})
        package_version = pyproject["project"]["version"]
        module = (root / "src/mesh_radio_manager/__init__.py").read_text(encoding="utf-8")
        self.assertIn(f'__version__ = "{package_version}"', module)
        self.assertIn("install-integration", postinst)
        self.assertIn("dpkg-buildpackage", ci)
        self.assertIn("build-essential", ci)
        self.assertIn("reprepro", ci)
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
        self.assertIn("actions/upload-pages-artifact@v5", release)
        self.assertIn("actions/upload-artifact@v7", release)
        self.assertIn("actions/deploy-pages@v5", release)
        self.assertIn("actions/download-artifact@v7", release)
        self.assertIn("APT_GPG_PRIVATE_KEY_BASE64", release)
        self.assertIn("APT_GPG_PASSPHRASE", release)
        self.assertIn('if [[ -n "$APT_GPG_PASSPHRASE" ]]', release)
        self.assertIn("--pinentry-mode loopback", release)
        self.assertIn("--passphrase-fd 0", release)
        self.assertIn("Remove temporary APT archive key", release)
        self.assertIn('gpgconf --homedir "$key_home" --kill all', release)
        self.assertIn("Install signing prerequisites", release)
        self.assertIn("build-essential", release)
        self.assertIn("actions/checkout@v7", release)
        self.assertIn("actions/setup-python@v7", release)
        self.assertIn('mktemp -d "${RUNNER_TEMP:?}/mesh-radio-manager-gpg.XXXXXX"', release)
        self.assertLess(
            release.index("mkdir -p dist/release/mesh-radio-manager"),
            release.index(">dist/apt-source.env"),
        )
        self.assertIn("Architectures: amd64 arm64 source", release)
        self.assertNotIn("Architectures: amd64 arm64 all source", release)
        self.assertIn("GH_REPO: ${{ github.repository }}", release)
        self.assertIn("release_assets=(", release)
        self.assertIn('"${release_assets[@]}"', release)
        self.assertNotIn('gh release create "$GITHUB_REF_NAME" dist/*', release)
        self.assertIn("--exclude-drafts --exclude-pre-releases", release)
        self.assertIn('Skipping $previous_tag: no GitHub release exists.', release)
        self.assertIn('Release $previous_tag exists but has no downloadable mesh-radio-manager .deb asset.', release)
        documentation = (root / "docs/apt-repository.md").read_text(encoding="utf-8")
        self.assertIn("external secret manager", documentation)
        self.assertIn("APT_GPG_PASSPHRASE", documentation)
        self.assertNotIn("KeePassXC", documentation)
        self.assertNotIn("quick-generate-key", documentation)


if __name__ == "__main__":
    unittest.main()
