#!/usr/bin/env bash
# Mesh Radio Manager host installer for Proxmox VE.
#
# Styled after Proxmox VE Helper-Scripts conventions, but maintained here.
# openHop is never vendored: its official host installer is fetched at runtime.
set -Eeuo pipefail

OPENHOP_INSTALLER="https://raw.githubusercontent.com/openhop-dev/openhop_repeater/main/scripts/proxmox-install.sh"
MANAGER_INSTALLER="https://raw.githubusercontent.com/Szewcson/mesh-radio-manager/main/install.sh"
PVE_MANAGER_SCRIPT="https://raw.githubusercontent.com/Szewcson/mesh-radio-manager/main/scripts/proxmox-manage.sh"
DEFAULT_CHANNEL="alpha"

RD="\033[01;31m"
GN="\033[1;92m"
YW="\033[33m"
BL="\033[36m"
BLD="\033[1m"
CL="\033[m"

msg_info() { echo -e " ${BL}ℹ${CL} $*"; }
msg_ok() { echo -e " ${GN}✓${CL} $*"; }
msg_warn() { echo -e " ${YW}⚠${CL} $*"; }
msg_error() { echo -e " ${RD}✗${CL} $*" >&2; }

usage() {
  cat <<'EOF'
Usage: proxmox-install.sh [--ctid CTID] [--channel alpha|beta] [--no-meshtastic]

Without --ctid, invokes the official openHop Proxmox installer first, then
installs Mesh Radio Manager inside the newly-created LXC.

With --ctid, leaves LXC creation alone and installs Mesh Radio Manager into an
existing official openHop LXC.
EOF
}

ctid=""
channel="$DEFAULT_CHANNEL"
install_meshtastic=1
while (($#)); do
  case "$1" in
    --ctid)
      shift
      [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] || { msg_error "--ctid needs a numeric CTID"; exit 2; }
      ctid="$1"
      ;;
    --channel)
      shift
      [[ $# -gt 0 && ( "$1" == "alpha" || "$1" == "beta" ) ]] || {
        msg_error "--channel must be alpha or beta"; exit 2;
      }
      channel="$1"
      ;;
    --no-meshtastic) install_meshtastic=0 ;;
    -h|--help) usage; exit 0 ;;
    *) msg_error "Unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { msg_error "Run this from the Proxmox host as root"; exit 1; }
command -v pct >/dev/null || { msg_error "This script must run on a Proxmox VE host"; exit 1; }
command -v curl >/dev/null || { msg_error "curl is required on the Proxmox host"; exit 1; }

list_ctids() {
  pct list | awk 'NR > 1 {print $1}' | sort -n
}

host_quirks_changed=0
ensure_host_ch341_quirks() {
  local config_file="/etc/pve/lxc/${ctid}.conf"
  local device_allow="lxc.cgroup2.devices.allow: c 189:* rwm"
  local usb_mount="lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0"
  local upstream_rule='SUBSYSTEM=="usb", ATTR{idVendor}=="1a86", ATTR{idProduct}=="5512", MODE="0666"'
  local rule_file="/etc/udev/rules.d/99-ch341.rules"

  [[ -f "$config_file" ]] || { msg_error "Missing Proxmox LXC configuration: $config_file"; exit 1; }
  if grep -Eq '^unprivileged:[[:space:]]*1' "$config_file"; then
    msg_error "LXC ${ctid} is unprivileged. The official openHop USB setup requires a privileged LXC."
    msg_error "Create it with the official installer instead of converting an existing LXC in place."
    exit 1
  fi

  # These are the exact USB lines used by the official openHop Proxmox
  # installer. Add only missing entries; never rewrite the rest of the CT
  # configuration managed by Proxmox/the user.
  if ! grep -Fqx "$device_allow" "$config_file"; then
    printf '\n# CH341 USB passthrough for Mesh Radio Manager\n%s\n' "$device_allow" >>"$config_file"
    host_quirks_changed=1
  fi
  if ! grep -Fqx "$usb_mount" "$config_file"; then
    printf '%s\n' "$usb_mount" >>"$config_file"
    host_quirks_changed=1
  fi

  if [[ ! -f "$rule_file" ]]; then
    printf '%s\n' "$upstream_rule" >"$rule_file"
    chmod 0644 "$rule_file"
    host_quirks_changed=1
  elif grep -Fq 'ATTR{idVendor}=="1a86", ATTR{idProduct}=="5512"' "$rule_file"; then
    : # Preserve the official rule or a compatible existing user rule.
  else
    # Do not overwrite a user's unrelated 99-ch341.rules. An additive,
    # manager-named rule provides the same official permission quirk.
    rule_file="/etc/udev/rules.d/99-mesh-radio-manager-ch341.rules"
    if [[ ! -f "$rule_file" ]]; then
      printf '%s\n' "$upstream_rule" >"$rule_file"
      chmod 0644 "$rule_file"
      host_quirks_changed=1
    fi
  fi
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb --action=change
  msg_ok "Verified official CH341 host passthrough quirks"
}

choose_ctid() {
  local -a created=()
  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && created+=("$candidate")
  done < <(comm -13 <(printf '%s\n' "$1" | sort -n) <(list_ctids))

  if ((${#created[@]} == 1)); then
    ctid="${created[0]}"
    msg_ok "Detected newly-created LXC ${ctid}"
    return
  fi
  msg_warn "Could not uniquely detect the new LXC. Select the official openHop CTID."
  pct list
  while :; do
    read -r -p " CTID: " ctid
    [[ "$ctid" =~ ^[0-9]+$ ]] && pct status "$ctid" >/dev/null 2>&1 && return
    msg_warn "That CTID does not exist."
  done
}

if [[ -z "$ctid" ]]; then
  header_before="$(list_ctids)"
  echo -e "${BLD}Mesh Radio Manager — Proxmox host installer${CL}"
  msg_info "Starting the official openHop Proxmox installer. Complete its prompts."
  # Do not copy or patch this script; it is obtained directly from upstream.
  bash -c "$(curl -fsSL "$OPENHOP_INSTALLER")"
  choose_ctid "$header_before"
else
  pct status "$ctid" >/dev/null 2>&1 || { msg_error "LXC ${ctid} does not exist"; exit 1; }
fi

was_running=0
if pct status "$ctid" | grep -q 'status: running'; then
  was_running=1
fi
ensure_host_ch341_quirks

if ((host_quirks_changed && was_running)); then
  msg_info "Restarting LXC ${ctid} to apply USB passthrough changes"
  pct restart "$ctid"
elif (( ! was_running )); then
  msg_info "Starting LXC ${ctid}"
  pct start "$ctid"
fi

msg_info "Ensuring installer prerequisites exist in LXC ${ctid}"
pct exec "$ctid" -- bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y curl git python3-venv gnupg'

manager_command="curl -fsSL '$MANAGER_INSTALLER' | bash -s --"
if ((install_meshtastic)); then
  manager_command+=" --install-meshtastic --channel $channel"
fi
msg_info "Installing Mesh Radio Manager in LXC ${ctid}"
pct exec "$ctid" -- bash -lc "$manager_command"
pct exec "$ctid" -- /usr/local/bin/mesh-radio --version >/dev/null

msg_info "Installing Proxmox-host control panel"
if curl -fsSL "$PVE_MANAGER_SCRIPT" -o /usr/local/sbin/mesh-radio-pve; then
  chmod 0755 /usr/local/sbin/mesh-radio-pve
  msg_ok "Host panel installed: mesh-radio-pve --ctid ${ctid}"
else
  msg_warn "LXC installation succeeded, but the optional host panel could not be downloaded"
fi

ip_address="$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}')"
echo
msg_ok "Mesh Radio Manager installation complete"
echo -e " Container: ${GN}${ctid}${CL}"
echo -e " openHop UI: ${GN}http://${ip_address:-<LXC-IP>}:8000${CL}"
echo
echo "Next: the official openHop installer has already configured USB bus passthrough."
echo "Inspect the two radios, then assign them inside the LXC:"
echo "  pct enter ${ctid}"
echo "  systemctl stop openhop-repeater meshtasticd 2>/dev/null || true"
echo "  mesh-radio radios"
echo "  mesh-radio assign openhop <selector> --profile pinedio"
echo "  mesh-radio assign meshtastic <selector> --profile meshtadpole"
echo "  mesh-radio verify"
echo "  systemctl start meshtasticd && systemctl restart openhop-repeater"
echo
echo "Later, update all three components from inside the LXC with: mesh-radio update"
echo "Or open the Proxmox-host control panel: mesh-radio-pve --ctid ${ctid}"
