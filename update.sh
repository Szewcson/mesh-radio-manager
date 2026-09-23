#!/bin/sh
# Update only Mesh Radio Manager. It deliberately never invokes openHop update.
set -eu

manager_root=/opt/mesh-radio-manager
source_dir=$manager_root/source

[ "$(id -u)" -eq 0 ] || { echo "Run update as root." >&2; exit 1; }
[ -d "$source_dir/.git" ] || {
    echo "This installation came from a release archive, not a Git checkout. Install a newer release using its install.sh." >&2
    exit 1
}
git -C "$source_dir" pull --ff-only
exec "$source_dir/install.sh"
