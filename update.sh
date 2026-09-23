#!/bin/sh
# Update Mesh Radio Manager; Meshtastic is opt-in and always explicit. This
# deliberately never invokes the official openHop updater.
set -eu

manager_root=/opt/mesh-radio-manager
source_dir=$manager_root/source
update_meshtastic=0
assume_yes=0

usage() {
    echo "Usage: sudo mesh-radio update [--meshtastic --yes]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --meshtastic) update_meshtastic=1 ;;
        --yes) assume_yes=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "Run update as root." >&2; exit 1; }
[ "$assume_yes" -eq 0 ] || [ "$update_meshtastic" -eq 1 ] || {
    echo "--yes is valid only together with --meshtastic." >&2
    exit 2
}
[ -d "$source_dir/.git" ] || {
    echo "This installation came from a release archive, not a Git checkout. Install a newer release using its install.sh." >&2
    exit 1
}

# Show package versions and require an explicit confirmation *before* changing
# either component. The CLI also handles configuration backup just before apt.
if [ "$update_meshtastic" -eq 1 ] && [ "$assume_yes" -eq 0 ]; then
    /usr/local/bin/mesh-radio meshtastic upgrade
    exit $?
fi

git -C "$source_dir" pull --ff-only
"$source_dir/install.sh"

if [ "$update_meshtastic" -eq 1 ]; then
    exec /usr/local/bin/mesh-radio meshtastic upgrade --yes
fi
