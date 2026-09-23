#!/bin/sh
# Update openHop through its official updater, then the signed Mesh Radio
# Manager package and meshtasticd. The openHop checkout is never copied or
# patched by this project.
set -eu

openhop_updater=/root/openhop-repeater/manage.sh
manager_update=/usr/lib/mesh-radio-manager/manager-update.sh
[ -x "$manager_update" ] || manager_update=/opt/mesh-radio-manager/manager-update.sh
manager_cli=/usr/bin/mesh-radio
[ -x "$manager_cli" ] || manager_cli=/usr/local/bin/mesh-radio

[ "$(id -u)" -eq 0 ] || { echo "Run update as root." >&2; exit 1; }
[ "$#" -eq 0 ] || { echo "Usage: sudo mesh-radio update" >&2; exit 2; }
[ -x "$openhop_updater" ] || {
    echo "Official openHop updater not found at $openhop_updater. Install openHop first; it was not modified." >&2
    exit 1
}
echo "=== Updating openHop with its official upstream updater ==="
# Upstream openHop recognises this variable and keeps its CLI upgrade path
# noninteractive. Do not pass --interactive here: host-side batch updates must
# never hang on the upstream whiptail UI.
PYMC_SILENT=1 "$openhop_updater" upgrade

echo "=== Updating Mesh Radio Manager ==="
"$manager_update"

echo "=== Updating meshtasticd ==="
# Show the exact package state before upgrading. `upgrade --yes` makes a
# timestamped backup of /etc/meshtasticd/config.yaml before apt runs.
"$manager_cli" meshtastic status
exec "$manager_cli" meshtastic upgrade --yes
