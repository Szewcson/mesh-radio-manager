"""Install only manager-owned systemd integration files atomically."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile

from .errors import ManagerError

SYSTEMD_DIR = Path("/etc/systemd/system")
OPENHOP_DROPIN = SYSTEMD_DIR / "openhop-repeater.service.d/20-mesh-radio-manager.conf"
MESHTASTIC_DROPIN = SYSTEMD_DIR / "meshtasticd.service.d/20-mesh-radio-manager.conf"
WEB_UNIT = SYSTEMD_DIR / "mesh-radio-manager-web.service"
TMPFILES = Path("/etc/tmpfiles.d/mesh-radio-manager.conf")

OPENHOP_DROPIN_TEXT = """# Managed by Mesh Radio Manager. Vendor openHop files are untouched.
[Service]
RuntimeDirectory=mesh-radio-manager
RuntimeDirectoryMode=0750
ExecStartPre=/usr/local/bin/mesh-radio internal prepare-openhop
ExecStart=
ExecStart=/opt/openhop_repeater/venv/bin/python -m repeater.main --config /run/mesh-radio-manager/openhop-config.yaml
"""

MESHTASTIC_DROPIN_TEXT = """# Managed by Mesh Radio Manager. USB isolation happens in a private namespace.
[Service]
User=root
Group=root
PrivateMounts=yes
NoNewPrivileges=no
ExecStart=
ExecStart=/usr/local/bin/mesh-radio internal run-meshtastic
"""

WEB_UNIT_TEXT = """[Unit]
Description=Mesh Radio Manager diagnostics UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mesh-radio web serve
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
"""


def _atomic_write(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def upstream_unit_supported(unit_text: str) -> bool:
    """Ensure this drop-in does not guess at a changed upstream service command."""
    return "repeater.main" in unit_text and "openhop_repeater" in unit_text


def _systemctl(*args: str, check: bool = True) -> str:
    try:
        result = subprocess.run(["systemctl", *args], text=True, capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ManagerError(f"systemctl {' '.join(args)} failed: {error}") from error
    if check and result.returncode:
        raise ManagerError((result.stderr or result.stdout).strip() or f"systemctl {' '.join(args)} failed")
    return result.stdout


def install(*, enable_web: bool = False) -> None:
    unit_text = _systemctl("cat", "openhop-repeater.service")
    if not upstream_unit_supported(unit_text):
        raise ManagerError(
            "The installed openHop unit is not a supported upstream layout; refusing to install "
            "a drop-in that could change its behavior. Update Mesh Radio Manager first."
        )
    _atomic_write(OPENHOP_DROPIN, OPENHOP_DROPIN_TEXT)
    _atomic_write(MESHTASTIC_DROPIN, MESHTASTIC_DROPIN_TEXT)
    _atomic_write(WEB_UNIT, WEB_UNIT_TEXT)
    _atomic_write(TMPFILES, "d /run/mesh-radio-manager 0750 root root -\n")
    _systemctl("daemon-reload")
    _systemctl("enable", "meshtasticd.service", check=False)
    if enable_web:
        _systemctl("enable", "--now", "mesh-radio-manager-web.service")


def uninstall() -> None:
    # These paths are fixed manager-owned targets. No vendor unit/configuration
    # is removed or rewritten.
    _systemctl("disable", "--now", "mesh-radio-manager-web.service", check=False)
    for path in (OPENHOP_DROPIN, MESHTASTIC_DROPIN, WEB_UNIT, TMPFILES):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    _systemctl("daemon-reload", check=False)
