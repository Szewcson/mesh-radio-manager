#!/bin/sh
# Install Mesh Radio Manager next to an official openHop LXC installation.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
manager_root=/opt/mesh-radio-manager
config_dir=/etc/mesh-radio-manager
install_meshtastic=0
enable_web=0
channel=beta

if [ ! -f "$project_dir/pyproject.toml" ] || [ ! -f "$project_dir/src/mesh_radio_manager/__init__.py" ]; then
    # Supports the documented `curl ... | sudo bash` path without vendoring
    # openHop. Download only this repository and re-enter its checked archive.
    bootstrap_dir=$(mktemp -d /tmp/mesh-radio-manager.XXXXXX)
    trap 'rm -rf "$bootstrap_dir"' EXIT HUP INT TERM
    curl -fsSL https://github.com/Szewcson/mesh-radio-manager/archive/refs/heads/main.tar.gz -o "$bootstrap_dir/source.tar.gz"
    tar -xzf "$bootstrap_dir/source.tar.gz" -C "$bootstrap_dir"
    archive_dir=$(find "$bootstrap_dir" -mindepth 1 -maxdepth 1 -type d -name 'mesh-radio-manager-*' | head -n 1)
    [ -n "$archive_dir" ] && [ -f "$archive_dir/pyproject.toml" ] || {
        echo "Downloaded Mesh Radio Manager archive is incomplete." >&2
        exit 1
    }
    "$archive_dir/install.sh" "$@"
    exit $?
fi

usage() {
    echo "Usage: sudo ./install.sh [--install-meshtastic] [--channel alpha|beta] [--web]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-meshtastic) install_meshtastic=1 ;;
        --web) enable_web=1 ;;
        --channel)
            shift
            [ "$#" -gt 0 ] || { usage; exit 2; }
            channel=$1
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "Run this installer as root." >&2; exit 1; }
[ -d /root/openhop-repeater ] && [ -f /etc/openhop_repeater/config.yaml ] || {
    echo "Official openHop LXC installation not detected. Install openHop from openhop-dev/openhop_repeater first." >&2
    exit 1
}
[ "$channel" = alpha ] || [ "$channel" = beta ] || { echo "Channel must be alpha or beta." >&2; exit 2; }

# Keep all project code/state separate from upstream. No source or vendor unit
# under /root/openhop-repeater or /opt/openhop_repeater is touched here.
install -d -m 0755 "$manager_root/source" "$config_dir" /var/lib/mesh-radio-manager /var/log/mesh-radio-manager
if [ "$project_dir" != "$manager_root/source" ]; then
    cp -a "$project_dir/." "$manager_root/source/"
fi
python3 -m venv "$manager_root/venv"
"$manager_root/venv/bin/pip" install --upgrade "$manager_root/source"
if [ ! -x "$manager_root/venv/bin/mesh-radio" ]; then
    echo "Mesh Radio Manager installation did not create its CLI launcher." >&2
    exit 1
fi
ln -sfn "$manager_root/venv/bin/mesh-radio" /usr/local/bin/mesh-radio
if ! /usr/local/bin/mesh-radio --version >/dev/null; then
    echo "Mesh Radio Manager CLI launcher validation failed." >&2
    exit 1
fi
# Some `pct enter` shells use a root PATH without /usr/local/bin. Provide a
# compatibility link in /usr/bin, but never replace a binary we do not own.
compat_launcher=/usr/bin/mesh-radio
if [ -e "$compat_launcher" ] || [ -L "$compat_launcher" ]; then
    compat_target=$(readlink -f "$compat_launcher" 2>/dev/null || true)
    [ "$compat_target" = "$manager_root/venv/bin/mesh-radio" ] || {
        echo "Refusing to replace existing non-manager launcher: $compat_launcher" >&2
        exit 1
    }
else
    ln -s /usr/local/bin/mesh-radio "$compat_launcher"
fi
if ! "$compat_launcher" --version >/dev/null; then
    echo "Mesh Radio Manager compatibility launcher validation failed." >&2
    exit 1
fi
install -m 0750 "$manager_root/source/update.sh" "$manager_root/update.sh"
install -m 0755 "$manager_root/source/scripts/mesh-radio-menu" /usr/local/bin/mesh-radio-menu
install -m 0644 "$manager_root/source/scripts/mesh-radio-manager-profile.sh" /etc/profile.d/mesh-radio-manager.sh
if [ ! -f "$config_dir/config.yaml" ]; then
    install -m 0640 "$manager_root/source/config/config.example.yaml" "$config_dir/config.yaml"
fi
if getent group repeater >/dev/null 2>&1; then
    chown root:repeater "$config_dir" "$config_dir/config.yaml"
    chmod 0750 "$config_dir"
    chmod 0640 "$config_dir/config.yaml"
fi

if [ "$enable_web" -eq 1 ]; then
    /usr/local/bin/mesh-radio install-integration --web
else
    /usr/local/bin/mesh-radio install-integration
fi
if [ "$install_meshtastic" -eq 1 ]; then
    # meshtasticd's upstream OBS repository key is armored; gpg is required
    # before the manager can convert it into an apt keyring.
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg
    /usr/local/bin/mesh-radio meshtastic install --channel "$channel"
fi

echo "Mesh Radio Manager installed. Assign radios with: mesh-radio radios"
