#!/bin/sh
# Remove manager-owned integration. openHop and meshtasticd remain installed.
set -eu

[ "$(id -u)" -eq 0 ] || { echo "Run uninstall as root." >&2; exit 1; }
manager_python=/opt/mesh-radio-manager/venv/bin/python
if [ -x "$manager_python" ]; then
    # Removing drop-ins requires a reload; do not edit any vendor unit.
    "$manager_python" -c 'from mesh_radio_manager.integration import uninstall; uninstall()' || true
fi
compat_launcher=/usr/bin/mesh-radio
if [ "$(readlink -f "$compat_launcher" 2>/dev/null || true)" = "/opt/mesh-radio-manager/venv/bin/mesh-radio" ]; then
    rm -f "$compat_launcher"
fi
rm -f /usr/local/bin/mesh-radio
rm -f /usr/local/bin/mesh-radio-menu /etc/profile.d/mesh-radio-manager.sh
rm -rf /opt/mesh-radio-manager /etc/mesh-radio-manager /var/lib/mesh-radio-manager /var/log/mesh-radio-manager
systemctl daemon-reload || true
if systemctl is-enabled --quiet openhop-repeater.service; then
    systemctl restart openhop-repeater.service || true
fi
echo "Mesh Radio Manager removed. openHop and meshtasticd files were preserved."
