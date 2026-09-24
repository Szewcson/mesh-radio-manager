#!/usr/bin/env bash
# Device-scoped USBFS passthrough for a Mesh Radio Manager LXC.
#
# The radios use libusb and therefore need their runtime /dev/bus/usb path.
# PVE's devN passthrough grants the cgroup permission for only the resolved
# character device; the existing USBFS bind mount provides the conventional
# path without granting access to every other USB device.
set -Eeuo pipefail

SYS_USB_ROOT=${MESH_RADIO_SYS_USB_ROOT:-/sys/bus/usb/devices}
DEV_ROOT=${MESH_RADIO_DEV_ROOT:-/dev}
DEV_USB_ROOT="$DEV_ROOT/bus/usb"
STATE_DIR=${MESH_RADIO_PVE_USB_STATE_DIR:-/etc/mesh-radio-manager/pve-usb}
UDEV_DIR=${MESH_RADIO_UDEV_DIR:-/etc/udev/rules.d}
PVE_CONFIG_DIR=${MESH_RADIO_PVE_LXC_DIR:-/etc/pve/lxc}
PCT=${MESH_RADIO_PCT:-pct}
UDEVADM=${MESH_RADIO_UDEVADM:-udevadm}
LOCK_DIR=${MESH_RADIO_PVE_USB_LOCK_DIR:-/run/mesh-radio-manager}
LOCK_FILE="$LOCK_DIR/proxmox-usb-handoff.lock"

WILDCARD_ALLOW='lxc.cgroup2.devices.allow: c 189:* rwm'
USB_MOUNT='lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0'
LEGACY_UDEV_ALLOW='SUBSYSTEM=="usb", ATTR{idVendor}=="1a86", ATTR{idProduct}=="5512", MODE="0666"'
PLUGDEV_GROUP=plugdev
RECORD_SEPARATOR=$'\x1f'

# Set by prepare_device_access() immediately before a host policy is written.
# In the unprivileged case the host-side numeric GID is deliberately different
# from the GID visible inside the container.
container_access_mode=""
container_plugdev_gid=""
host_device_gid=""
udev_device_group="$PLUGDEV_GROUP"
pve_device_gid=0
pve_device_mode=0600

msg_info() { printf 'INFO: %s\n' "$*"; }
msg_ok() { printf 'OK: %s\n' "$*"; }
msg_warn() { printf 'WARNING: %s\n' "$*" >&2; }
msg_error() { printf 'ERROR: %s\n' "$*" >&2; }

acquire_usb_lock() {
  command -v flock >/dev/null || { msg_error "flock is required on the Proxmox host."; return 1; }
  install -d -m 0750 "$LOCK_DIR"
  exec 8>"$LOCK_FILE"
  flock -n 8 || { msg_error "Another USB handoff operation is already running."; return 1; }
}

usage() {
  cat <<'EOF'
Usage:
  proxmox-usb.sh list
  proxmox-usb.sh preflight
  proxmox-usb.sh status --ctid CTID
  proxmox-usb.sh secure --ctid CTID --openhop-selector SELECTOR \
    --meshtastic-selector SELECTOR --yes
  proxmox-usb.sh bootstrap --ctid CTID --openhop-selector SELECTOR \
    --meshtastic-selector SELECTOR --yes
  proxmox-usb.sh refresh --ctid CTID --yes

Selectors are host identities printed by `list`:
  serial:<USB-iSerial>  (MeshtasticD permits at most eight ASCII bytes)
  port:<controller>/ports/<physical-port-chain>

`secure` stops and starts the LXC. It retains the USBFS bind mount for libusb,
but replaces c 189:* with PVE devN grants for exactly the two assigned radios.
The physical port is part of the host authorization even for a serial-numbered
radio. Moving a radio fails closed; run secure again with the new port.

For a fresh unprivileged LXC, secure maps its in-container plugdev GID through
/proc/1/gid_map and writes only that mapped numeric GID to the host udev rule.
It never converts an existing container between privilege modes.

`bootstrap` is only for a fresh unprivileged LXC before its first radio
assignments exist. It grants the two explicit host-selected radios, starts the
CT, and records a bootstrap state. Create the assignments inside the CT, then
run `secure` with the same selectors to validate the services and finalize it.

`preflight` checks that no broad CH341 `MODE="0666"` host rule would weaken a
fresh unprivileged deployment. It does not inspect or alter any LXC.
EOF
}

if [[ ${EUID:-1} -ne 0 ]]; then
  # The non-root path is only for the hermetic test harness. It requires every
  # host-mutating root to be redirected away from its production location, so
  # it cannot make a real PVE host invocation less privileged.
  [[ ${MESH_RADIO_TEST_MODE:-0} == 1 && "$DEV_ROOT" != /dev && "$PVE_CONFIG_DIR" != /etc/pve/lxc && "$UDEV_DIR" != /etc/udev/rules.d && "$LOCK_DIR" != /run/mesh-radio-manager ]] || {
    msg_error "Run this from the Proxmox host as root."
    exit 1
  }
fi
command -v "$PCT" >/dev/null || { msg_error "Proxmox pct command not found."; exit 1; }
command -v "$UDEVADM" >/dev/null || { msg_error "udevadm is required."; exit 1; }

command_name=${1:-}
[[ -n "$command_name" ]] || { usage >&2; exit 2; }
shift

ctid=""
openhop_selector=""
meshtastic_selector=""
assume_yes=0
while (($#)); do
  case "$1" in
    --ctid)
      shift
      [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
      ctid=$1
      ;;
    --openhop-selector)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 2; }
      openhop_selector=$1
      ;;
    --meshtastic-selector)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 2; }
      meshtastic_selector=$1
      ;;
    --yes) assume_yes=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$command_name" in
  list|preflight)
    [[ -z "$ctid$openhop_selector$meshtastic_selector" && $assume_yes -eq 0 ]] || { usage >&2; exit 2; }
    ;;
  status|refresh|secure|bootstrap)
    [[ -n "$ctid" ]] || { msg_error "--ctid is required."; exit 2; }
    ;;
  *) usage >&2; exit 2 ;;
esac
if [[ "$command_name" == secure || "$command_name" == bootstrap ]]; then
  [[ -n "$openhop_selector" && -n "$meshtastic_selector" && $assume_yes -eq 1 ]] || {
    msg_error "$command_name requires both selectors and --yes because it restarts the LXC."
    exit 2
  }
elif [[ "$command_name" == refresh ]]; then
  [[ -z "$openhop_selector$meshtastic_selector" && $assume_yes -eq 1 ]] || {
    msg_error "refresh accepts no selectors and requires --yes because it restarts the LXC."
    exit 2
  }
elif [[ "$command_name" == status ]]; then
  [[ -z "$openhop_selector$meshtastic_selector" && $assume_yes -eq 0 ]] || { usage >&2; exit 2; }
fi

ct_config() { printf '%s/%s.conf\n' "$PVE_CONFIG_DIR" "$ctid"; }
state_file() { printf '%s/%s.conf\n' "$STATE_DIR" "$ctid"; }
udev_rule_file() { printf '%s/99-mesh-radio-manager-%s.rules\n' "$UDEV_DIR" "$ctid"; }
role_alias() { printf '%s/mesh-radio-manager/ct%s-%s\n' "$DEV_ROOT" "$ctid" "$1"; }

read_trimmed() {
  local path=$1 value
  [[ -r "$path" ]] || return 1
  IFS= read -r value <"$path" || true
  printf '%s' "$value"
}

stable_port_path() {
  local entry=$1 resolved remainder component leaf controller=""
  local -a components=()
  local index prefix
  resolved=$(readlink -f -- "$entry") || return 1
  [[ "$resolved" == */devices/* ]] || return 1
  remainder=${resolved#*/devices/}
  IFS=/ read -r -a components <<<"$remainder"
  for ((index = 0; index + 1 < ${#components[@]}; index++)); do
    component=${components[index]}
    leaf=${components[index + 1]}
    if [[ "$component" =~ ^usb[0-9]+$ && "$leaf" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]]; then
      for ((prefix = 0; prefix < index; prefix++)); do
        controller+="${controller:+/}${components[prefix]}"
      done
      [[ -n "$controller" ]] || return 1
      printf '%s/ports/%s\n' "$controller" "${leaf#*-}"
      return 0
    fi
  done
  return 1
}

id_path_for_node() {
  "$UDEVADM" info --query=property --name "$1" 2>/dev/null |
    awk -F= '$1 == "ID_PATH" { print substr($0, 9); exit }'
}

discover_ch341() {
  local entry name vid pid bus address node serial port_path id_path
  shopt -s nullglob
  for entry in "$SYS_USB_ROOT"/*; do
    [[ -d "$entry" ]] || continue
    name=${entry##*/}
    [[ "$name" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]] || continue
    vid=$(read_trimmed "$entry/idVendor" 2>/dev/null || true)
    pid=$(read_trimmed "$entry/idProduct" 2>/dev/null || true)
    [[ "${vid,,}" == 1a86 && "${pid,,}" == 5512 ]] || continue
    bus=$(read_trimmed "$entry/busnum" 2>/dev/null || true)
    address=$(read_trimmed "$entry/devnum" 2>/dev/null || true)
    [[ "$bus" =~ ^[0-9]+$ && "$address" =~ ^[0-9]+$ ]] || continue
    printf -v node '%s/%03d/%03d' "$DEV_USB_ROOT" "$((10#$bus))" "$((10#$address))"
    [[ -c "$node" ]] || continue
    serial=$(read_trimmed "$entry/serial" 2>/dev/null || true)
    port_path=$(stable_port_path "$entry" 2>/dev/null || true)
    id_path=$(id_path_for_node "$node")
    [[ "$serial" != *"$RECORD_SEPARATOR"* && "$serial" != *$'\n'* ]] || continue
    [[ "$port_path" != *"$RECORD_SEPARATOR"* && "$id_path" != *"$RECORD_SEPARATOR"* && -n "$port_path" && -n "$id_path" ]] || continue
    if ! valid_port_selector "port:$port_path" || ! valid_udev_value "$id_path" ||
      { [[ -n "$serial" ]] && ! valid_udev_value "$serial"; }; then
        msg_warn "Ignoring CH341 device with unsafe USB metadata at $node."
        continue
    fi
    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
      "${vid,,}" "$RECORD_SEPARATOR" "${pid,,}" "$RECORD_SEPARATOR" "$bus" "$RECORD_SEPARATOR" "$address" "$RECORD_SEPARATOR" \
      "$node" "$RECORD_SEPARATOR" "$serial" "$RECORD_SEPARATOR" "$port_path" "$RECORD_SEPARATOR" "$id_path"
  done
}

valid_port_selector() {
  [[ "$1" =~ ^port:([A-Za-z0-9_.:-]+/)*ports/[0-9]+(\.[0-9]+)*$ ]]
}

valid_serial_selector() {
  [[ "$1" =~ ^serial:[A-Za-z0-9._-]{1,64}$ ]]
}

validate_selector() {
  valid_port_selector "$1" || valid_serial_selector "$1"
}

# Values included in a udev rule must be constrained independently from the
# user-facing selector grammar.  USB descriptors are device-controlled input;
# allowing quotes, commas, whitespace, or shell metacharacters here could
# create an additional udev rule rather than an exact device match.
valid_udev_value() {
  [[ "$1" =~ ^[A-Za-z0-9._:+/-]{1,256}$ ]]
}

validate_record_for_udev() {
  local record=$1 vid pid serial port_path id_path
  vid=$(record_field "$record" 1)
  pid=$(record_field "$record" 2)
  serial=$(record_field "$record" 6)
  port_path=$(record_field "$record" 7)
  id_path=$(record_field "$record" 8)
  [[ "$vid" == 1a86 && "$pid" == 5512 ]] || return 1
  valid_port_selector "port:$port_path" || return 1
  valid_udev_value "$id_path" || return 1
  [[ -z "$serial" ]] || valid_udev_value "$serial"
}

resolve_selector() {
  local role=$1 selector=$2 record vid pid bus address node serial port_path id_path expected
  local -a matches=()
  validate_selector "$selector" || {
    msg_error "$role selector is invalid; use a selector printed by list."
    return 1
  }
  expected=${selector#*:}
  while IFS="$RECORD_SEPARATOR" read -r vid pid bus address node serial port_path id_path; do
    if [[ "$selector" == serial:* && "$serial" == "$expected" ]]; then
      matches+=("$vid$RECORD_SEPARATOR$pid$RECORD_SEPARATOR$bus$RECORD_SEPARATOR$address$RECORD_SEPARATOR$node$RECORD_SEPARATOR$serial$RECORD_SEPARATOR$port_path$RECORD_SEPARATOR$id_path")
    elif [[ "$selector" == port:* && "$port_path" == "$expected" ]]; then
      matches+=("$vid$RECORD_SEPARATOR$pid$RECORD_SEPARATOR$bus$RECORD_SEPARATOR$address$RECORD_SEPARATOR$node$RECORD_SEPARATOR$serial$RECORD_SEPARATOR$port_path$RECORD_SEPARATOR$id_path")
    fi
  done < <(discover_ch341)
  if ((${#matches[@]} == 0)); then
    msg_error "No CH341 radio matches $role selector '$selector'."
    return 1
  fi
  if ((${#matches[@]} != 1)); then
    msg_error "$role selector '$selector' matches multiple radios; refusing an ambiguous handoff."
    return 1
  fi
  printf '%s\n' "${matches[0]}"
}

record_field() {
  local record=$1 number=$2
  cut -d "$RECORD_SEPARATOR" -f "$number" <<<"$record"
}

container_mode() {
  local config
  config=$(ct_config)
  [[ -f "$config" ]] || { msg_error "Missing LXC config: $config"; return 1; }
  if grep -Eq '^unprivileged:[[:space:]]*1([[:space:]]|$)' "$config"; then
    printf 'unprivileged\n'
  else
    printf 'privileged\n'
  fi
}

ct_state() {
  "$PCT" status "$ctid" 2>/dev/null | awk '{print $2}'
}

ct_is_running() {
  [[ $(ct_state) == running ]]
}

container_plugdev_group_id() {
  "$PCT" exec "$ctid" -- getent group "$PLUGDEV_GROUP" 2>/dev/null |
    awk -F: 'NR == 1 {print $3}'
}

map_container_id_to_host() {
  local container_id=$1 mapping=$2
  awk -v wanted="$container_id" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
      if (wanted >= $1 && wanted - $1 < $3) {
        print $2 + wanted - $1
        found = 1
        exit
      }
    }
    END { exit !found }
  ' <<<"$mapping"
}

prepare_device_access() {
  local host_gid gid_map mapped_gid
  container_access_mode=$(container_mode) || return 1
  ct_is_running || {
    msg_error "LXC $ctid must be running while secure validates its user/group mapping."
    return 1
  }
  container_plugdev_gid=$(container_plugdev_group_id)
  [[ "$container_plugdev_gid" =~ ^[0-9]+$ ]] || {
    msg_error "The LXC must provide group '$PLUGDEV_GROUP'."
    return 1
  }
  case "$container_access_mode" in
    privileged)
      host_gid=$(getent group "$PLUGDEV_GROUP" | awk -F: 'NR == 1 {print $3}')
      [[ "$host_gid" =~ ^[0-9]+$ && "$host_gid" == "$container_plugdev_gid" ]] || {
        msg_error "Host plugdev GID ${host_gid:-missing} differs from LXC plugdev GID $container_plugdev_gid."
        return 1
      }
      host_device_gid=$host_gid
      udev_device_group=$PLUGDEV_GROUP
      pve_device_gid=0
      pve_device_mode=0600
      ;;
    unprivileged)
      gid_map=$("$PCT" exec "$ctid" -- cat /proc/1/gid_map 2>/dev/null) || {
        msg_error "Could not read the unprivileged LXC GID map."
        return 1
      }
      mapped_gid=$(map_container_id_to_host "$container_plugdev_gid" "$gid_map") || {
        msg_error "The LXC plugdev GID is not mapped to the host; refusing USB access."
        return 1
      }
      [[ "$mapped_gid" =~ ^[0-9]+$ ]] || {
        msg_error "The mapped host plugdev GID is invalid."
        return 1
      }
      host_device_gid=$mapped_gid
      udev_device_group=$host_device_gid
      pve_device_gid=$container_plugdev_gid
      pve_device_mode=0660
      ;;
    *)
      msg_error "Unsupported LXC privilege mode: $container_access_mode."
      return 1
      ;;
  esac
}

ensure_ct_usb_mount() {
  local config
  config=$(ct_config)
  if ! grep -Fqx "$USB_MOUNT" "$config"; then
    printf '\n# USBFS visibility for libusb; devN provides device access control.\n%s\n' "$USB_MOUNT" >>"$config"
  fi
}

has_usb_wildcard() {
  grep -Eq '^lxc\.cgroup2\.devices\.allow:[[:space:]]+c[[:space:]]+189:\*[[:space:]]' "$(ct_config)"
}

remove_exact_line() {
  local file=$1 line=$2 temporary
  temporary=$(mktemp "${file}.mesh-radio.XXXXXX")
  awk -v expected="$line" '$0 != expected { print }' "$file" >"$temporary"
  chmod --reference="$file" "$temporary"
  chown --reference="$file" "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$file"
}

remove_legacy_broad_udev_rules() {
  local file
  for file in "$UDEV_DIR/99-ch341.rules" "$UDEV_DIR/99-mesh-radio-manager-ch341.rules"; do
    [[ -f "$file" ]] || continue
    remove_exact_line "$file" "$LEGACY_UDEV_ALLOW"
  done
}

remaining_broad_udev_rules() {
  local file
  shopt -s nullglob
  for file in "$UDEV_DIR"/*.rules; do
    if awk '
      index($0, "ATTR{idVendor}==\"1a86\"") &&
      index($0, "ATTR{idProduct}==\"5512\"") &&
      index($0, "MODE=\"0666\"") { found = 1 }
      END { exit !found }
    ' "$file"; then
      printf '%s\n' "$file"
    fi
  done
}

unexpected_broad_udev_rules() {
  local file
  shopt -s nullglob
  for file in "$UDEV_DIR"/*.rules; do
    awk -v legacy="$LEGACY_UDEV_ALLOW" -v first="$UDEV_DIR/99-ch341.rules" \
      -v second="$UDEV_DIR/99-mesh-radio-manager-ch341.rules" '
      index($0, "ATTR{idVendor}==\"1a86\"") &&
      index($0, "ATTR{idProduct}==\"5512\"") &&
      index($0, "MODE=\"0666\"") {
        if ((FILENAME == first || FILENAME == second) && $0 == legacy) next
        printf "%s:%d\\n", FILENAME, FNR
      }
    ' "$file"
  done
}

next_free_dev_slots() {
  local config used slot first="" second=""
  config=$(ct_config)
  for slot in {0..9}; do
    used=$(grep -Ec "^dev${slot}:" "$config" || true)
    ((used == 0)) || continue
    if [[ -z "$first" ]]; then
      first=$slot
    else
      second=$slot
      break
    fi
  done
  [[ -n "$first" && -n "$second" ]] || {
    msg_error "No two free PVE devN slots are available for LXC $ctid."
    return 1
  }
  printf '%s\t%s\n' "$first" "$second"
}

write_udev_rule() {
  local openhop_record=$1 meshtastic_record=$2 temporary file
  local openhop_vid openhop_pid openhop_serial openhop_id_path
  local meshtastic_vid meshtastic_pid meshtastic_serial meshtastic_id_path
  openhop_vid=$(record_field "$openhop_record" 1)
  openhop_pid=$(record_field "$openhop_record" 2)
  openhop_serial=$(record_field "$openhop_record" 6)
  openhop_id_path=$(record_field "$openhop_record" 8)
  meshtastic_vid=$(record_field "$meshtastic_record" 1)
  meshtastic_pid=$(record_field "$meshtastic_record" 2)
  meshtastic_serial=$(record_field "$meshtastic_record" 6)
  meshtastic_id_path=$(record_field "$meshtastic_record" 8)
  validate_record_for_udev "$openhop_record" || {
    msg_error "openHop device metadata is unsafe for a udev rule."
    return 1
  }
  validate_record_for_udev "$meshtastic_record" || {
    msg_error "Meshtastic device metadata is unsafe for a udev rule."
    return 1
  }
  file=$(udev_rule_file)
  install -d -m 0755 "$UDEV_DIR"
  temporary=$(mktemp "${file}.XXXXXX")
  {
    printf '# Managed by Mesh Radio Manager. Do not edit; run mesh-radio-pve --secure-usb to reprovision.\n'
    printf 'SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="%s", ATTR{idProduct}=="%s", ENV{ID_PATH}=="%s"' \
      "$openhop_vid" "$openhop_pid" "$openhop_id_path"
    [[ -n "$openhop_serial" ]] && printf ', ATTR{serial}=="%s"' "$openhop_serial"
    printf ', SYMLINK+="mesh-radio-manager/ct%s-openhop", GROUP="%s", MODE="0660"\n' "$ctid" "$udev_device_group"
    printf 'SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="%s", ATTR{idProduct}=="%s", ENV{ID_PATH}=="%s"' \
      "$meshtastic_vid" "$meshtastic_pid" "$meshtastic_id_path"
    [[ -n "$meshtastic_serial" ]] && printf ', ATTR{serial}=="%s"' "$meshtastic_serial"
    printf ', SYMLINK+="mesh-radio-manager/ct%s-meshtastic", GROUP="%s", MODE="0660"\n' "$ctid" "$udev_device_group"
  } >"$temporary"
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$file"
  "$UDEVADM" control --reload-rules
  "$UDEVADM" trigger --subsystem-match=usb --action=change
  "$UDEVADM" settle --timeout=10
}

verify_alias() {
  local role=$1 record=$2 alias expected resolved expected_rdev resolved_rdev
  alias=$(role_alias "$role")
  expected=$(record_field "$record" 5)
  resolved=$(readlink -f -- "$alias" 2>/dev/null || true)
  expected_rdev=$(stat -Lc '%t:%T' "$expected" 2>/dev/null || true)
  resolved_rdev=$(stat -Lc '%t:%T' "$resolved" 2>/dev/null || true)
  [[ -c "$expected" && -c "$resolved" && -n "$expected_rdev" && "$expected_rdev" == "$resolved_rdev" ]] || {
    msg_error "Stable alias $alias does not resolve to expected USB node $expected."
    return 1
  }
}

write_state() {
  local openhop_record=$1 meshtastic_record=$2 openhop_slot=$3 meshtastic_slot=$4 phase=${5:-active} temporary file
  [[ "$phase" == active || "$phase" == bootstrap ]] || {
    msg_error "Invalid USB handoff state phase."
    return 1
  }
  file=$(state_file)
  install -d -m 0700 "$STATE_DIR"
  temporary=$(mktemp "${file}.XXXXXX")
  chmod 0600 "$temporary"
  {
    printf 'version=3\nctid=%s\nstate_phase=%s\n' "$ctid" "$phase"
    printf 'container_mode=%s\n' "$container_access_mode"
    printf 'udev_device_group=%s\n' "$udev_device_group"
    printf 'pve_device_gid=%s\n' "$pve_device_gid"
    printf 'pve_device_mode=%s\n' "$pve_device_mode"
    printf 'openhop_selector=%s\n' "$openhop_selector"
    printf 'openhop_port_path=%s\n' "$(record_field "$openhop_record" 7)"
    printf 'openhop_id_path=%s\n' "$(record_field "$openhop_record" 8)"
    printf 'openhop_dev=dev%s\n' "$openhop_slot"
    printf 'meshtastic_selector=%s\n' "$meshtastic_selector"
    printf 'meshtastic_port_path=%s\n' "$(record_field "$meshtastic_record" 7)"
    printf 'meshtastic_id_path=%s\n' "$(record_field "$meshtastic_record" 8)"
    printf 'meshtastic_dev=dev%s\n' "$meshtastic_slot"
  } >"$temporary"
  mv -f -- "$temporary" "$file"
}

load_state() {
  local file key value
  file=$(state_file)
  [[ -r "$file" ]] || { msg_error "No hardened USB state exists for LXC $ctid."; return 1; }
  state_version=""; state_ctid=""; state_phase=""; state_container_mode=""; state_udev_device_group=""; state_pve_device_gid=""; state_pve_device_mode=""
  state_openhop_selector=""; state_openhop_port_path=""; state_openhop_id_path=""; state_openhop_dev=""
  state_meshtastic_selector=""; state_meshtastic_port_path=""; state_meshtastic_id_path=""; state_meshtastic_dev=""
  while IFS='=' read -r key value; do
    case "$key" in
      version) state_version=$value ;;
      ctid) state_ctid=$value ;;
      state_phase) state_phase=$value ;;
      container_mode) state_container_mode=$value ;;
      udev_device_group) state_udev_device_group=$value ;;
      pve_device_gid) state_pve_device_gid=$value ;;
      pve_device_mode) state_pve_device_mode=$value ;;
      openhop_selector) state_openhop_selector=$value ;;
      openhop_port_path) state_openhop_port_path=$value ;;
      openhop_id_path) state_openhop_id_path=$value ;;
      openhop_dev) state_openhop_dev=$value ;;
      meshtastic_selector) state_meshtastic_selector=$value ;;
      meshtastic_port_path) state_meshtastic_port_path=$value ;;
      meshtastic_id_path) state_meshtastic_id_path=$value ;;
      meshtastic_dev) state_meshtastic_dev=$value ;;
      ''|'#'*) ;;
      *) msg_error "Unexpected key in USB state: $key"; return 1 ;;
    esac
  done <"$file"
  case "$state_version" in
    1|2|3) ;;
    *) msg_error "Invalid USB state file $file."; return 1 ;;
  esac
  [[ "$state_ctid" == "$ctid" ]] || {
    msg_error "Invalid USB state file $file."; return 1;
  }
  if [[ "$state_version" == 1 ]]; then
    # Version 1 was the privileged-only format. Preserve it for existing
    # deployments; this is not an in-place privilege-mode migration.
    state_container_mode=privileged
    state_udev_device_group=$PLUGDEV_GROUP
    state_pve_device_gid=0
    state_pve_device_mode=0600
  fi
  if [[ "$state_version" == 1 || "$state_version" == 2 ]]; then
    # Pre-bootstrap state files describe completed handoffs only.
    state_phase=active
  fi
  [[ "$state_phase" == active || "$state_phase" == bootstrap ]] || {
    msg_error "USB state has an invalid handoff phase."
    return 1
  }
  case "$state_container_mode" in
    privileged)
      [[ "$state_udev_device_group" == "$PLUGDEV_GROUP" && "$state_pve_device_gid" == 0 && "$state_pve_device_mode" == 0600 ]] || {
        msg_error "Invalid privileged USB state permissions."; return 1;
      }
      ;;
    unprivileged)
      [[ "$state_udev_device_group" =~ ^[0-9]+$ && "$state_pve_device_gid" =~ ^[0-9]+$ && "$state_pve_device_mode" == 0660 ]] || {
        msg_error "Invalid unprivileged USB state permissions."; return 1;
      }
      ;;
    *) msg_error "USB state has an invalid container privilege mode."; return 1 ;;
  esac
  if ! validate_selector "$state_openhop_selector" || ! validate_selector "$state_meshtastic_selector"; then
    msg_error "USB state contains invalid selectors."; return 1;
  fi
  [[ "$state_openhop_dev" =~ ^dev[0-9]+$ && "$state_meshtastic_dev" =~ ^dev[0-9]+$ ]] || {
    msg_error "USB state contains invalid PVE devN slots."; return 1;
  }
  if ! valid_port_selector "port:$state_openhop_port_path" || ! valid_port_selector "port:$state_meshtastic_port_path" ||
    ! valid_udev_value "$state_openhop_id_path" || ! valid_udev_value "$state_meshtastic_id_path"; then
    msg_error "USB state contains invalid device identity fields."; return 1;
  fi
}

apply_state_device_access() {
  container_access_mode=$state_container_mode
  udev_device_group=$state_udev_device_group
  pve_device_gid=$state_pve_device_gid
  pve_device_mode=$state_pve_device_mode
}

state_matches_container_mode() {
  local current_mode
  current_mode=$(container_mode) || return 1
  [[ "$current_mode" == "$state_container_mode" ]] || {
    msg_error "LXC privilege mode changed from $state_container_mode to $current_mode; refusing USB access. Create a new LXC instead of converting this one."
    return 1
  }
}

state_matches_current_device_access() {
  [[ "$state_container_mode" == "$container_access_mode" &&
    "$state_udev_device_group" == "$udev_device_group" &&
    "$state_pve_device_gid" == "$pve_device_gid" &&
    "$state_pve_device_mode" == "$pve_device_mode" ]] || {
      msg_error "The LXC user/group mapping changed; refuse USB access until it is re-created with a stable map."
      return 1
    }
}

validate_state_devices() {
  local openhop_record meshtastic_record openhop_id_path meshtastic_id_path
  openhop_record=$(resolve_selector openhop "$state_openhop_selector") || return 1
  meshtastic_record=$(resolve_selector meshtastic "$state_meshtastic_selector") || return 1
  openhop_id_path=$(record_field "$openhop_record" 8)
  meshtastic_id_path=$(record_field "$meshtastic_record" 8)
  [[ "$openhop_id_path" == "$state_openhop_id_path" ]] || {
    msg_error "openHop radio moved from its authorized physical port; refusing handoff."
    return 1
  }
  [[ "$meshtastic_id_path" == "$state_meshtastic_id_path" ]] || {
    msg_error "Meshtastic radio moved from its authorized physical port; refusing handoff."
    return 1
  }
  verify_alias openhop "$openhop_record"
  verify_alias meshtastic "$meshtastic_record"
}

verify_pve_device_config() {
  local config expected_openhop expected_meshtastic
  config=$(ct_config)
  expected_openhop="${state_openhop_dev}: $(role_alias openhop),uid=0,gid=${state_pve_device_gid},mode=${state_pve_device_mode}"
  expected_meshtastic="${state_meshtastic_dev}: $(role_alias meshtastic),uid=0,gid=${state_pve_device_gid},mode=${state_pve_device_mode}"
  grep -Fqx "$expected_openhop" "$config" || { msg_error "Missing expected PVE device grant: $expected_openhop"; return 1; }
  grep -Fqx "$expected_meshtastic" "$config" || { msg_error "Missing expected PVE device grant: $expected_meshtastic"; return 1; }
  ! has_usb_wildcard || { msg_error "Unsafe c 189:* grant is still present."; return 1; }
}

wait_for_ct() {
  local attempt=0
  while ((attempt < 30)); do
    "$PCT" exec "$ctid" -- true >/dev/null 2>&1 && return 0
    sleep 1
    ((attempt += 1))
  done
  msg_error "LXC $ctid did not become ready within 30 seconds."
  return 1
}

restart_and_verify() {
  if ct_is_running; then
    "$PCT" shutdown "$ctid" --timeout 60 >/dev/null
    [[ $(ct_state) == stopped ]] || { msg_error "LXC $ctid did not stop cleanly."; return 1; }
  fi
  "$PCT" start "$ctid"
  wait_for_ct
  "$PCT" exec "$ctid" -- /usr/bin/mesh-radio verify >/dev/null
}

remove_provisioned_device_grants() {
  local openhop_slot=$1 meshtastic_slot=$2
  "$PCT" set "$ctid" --delete "dev${openhop_slot}" >/dev/null ||
    msg_warn "Could not remove temporary PVE grant dev${openhop_slot}; inspect $(ct_config)."
  "$PCT" set "$ctid" --delete "dev${meshtastic_slot}" >/dev/null ||
    msg_warn "Could not remove temporary PVE grant dev${meshtastic_slot}; inspect $(ct_config)."
}

restore_pre_hardening_state() {
  local openhop_slot=$1 meshtastic_slot=$2
  # This recovery path runs only before the broad cgroup permission is removed.
  # It removes the temporary exact grants and puts the previously-running CT
  # back into its compatibility state.
  if ct_is_running; then
    "$PCT" shutdown "$ctid" --timeout 60 >/dev/null || true
  fi
  remove_provisioned_device_grants "$openhop_slot" "$meshtastic_slot"
  "$PCT" start "$ctid" >/dev/null || msg_warn "Could not restart LXC $ctid after compatibility rollback."
}

restore_previous_udev_rule() {
  local backup=$1
  [[ -n "$backup" && -f "$backup" ]] || return 0
  mv -f -- "$backup" "$(udev_rule_file)"
  "$UDEVADM" control --reload-rules || return 1
  "$UDEVADM" trigger --subsystem-match=usb --action=change || return 1
  "$UDEVADM" settle --timeout=10
}

remove_new_bootstrap_policy() {
  local openhop_slot=$1 meshtastic_slot=$2 rule
  if ct_is_running; then
    "$PCT" shutdown "$ctid" --timeout 60 >/dev/null || true
  fi
  remove_provisioned_device_grants "$openhop_slot" "$meshtastic_slot"
  rule=$(udev_rule_file)
  if [[ -f "$rule" ]] && head -n 1 "$rule" | grep -Fqx '# Managed by Mesh Radio Manager. Do not edit; run mesh-radio-pve --secure-usb to reprovision.'; then
    rm -f -- "$rule"
    "$UDEVADM" control --reload-rules || true
    "$UDEVADM" trigger --subsystem-match=usb --action=change || true
    "$UDEVADM" settle --timeout=10 || true
  fi
  "$PCT" start "$ctid" >/dev/null || msg_warn "Could not restart LXC $ctid after bootstrap rollback."
}

bootstrap_usb() {
  local openhop_record meshtastic_record openhop_node meshtastic_node slots openhop_slot meshtastic_slot broad_rules
  [[ ! -f "$(state_file)" ]] || {
    msg_error "LXC $ctid already has USB handoff state; use secure or refresh instead of bootstrap."
    return 1
  }
  [[ ! -e "$(udev_rule_file)" ]] || {
    msg_error "Managed udev rule $(udev_rule_file) already exists without state; inspect it before provisioning."
    return 1
  }
  prepare_device_access || return 1
  [[ "$container_access_mode" == unprivileged ]] || {
    msg_error "bootstrap is only for a fresh unprivileged LXC; use secure for a privileged compatibility LXC."
    return 1
  }
  ! has_usb_wildcard || {
    msg_error "Unprivileged LXC $ctid must not have a c 189:* USB grant."
    return 1
  }
  broad_rules=$(remaining_broad_udev_rules || true)
  [[ -z "$broad_rules" ]] || {
    msg_error "Unprivileged LXC setup refuses host CH341 MODE=0666 udev rules: $broad_rules"
    return 1
  }
  openhop_record=$(resolve_selector openhop "$openhop_selector") || return 1
  meshtastic_record=$(resolve_selector meshtastic "$meshtastic_selector") || return 1
  openhop_node=$(record_field "$openhop_record" 5)
  meshtastic_node=$(record_field "$meshtastic_record" 5)
  [[ "$openhop_node" != "$meshtastic_node" ]] || { msg_error "Both roles resolve to the same USB device."; return 1; }
  if [[ "$meshtastic_selector" == serial:* && ! "$meshtastic_selector" =~ ^serial:[A-Za-z0-9._-]{1,8}$ ]]; then
    msg_error "Meshtastic USB serial must be one to eight safe ASCII bytes."
    return 1
  fi
  slots=$(next_free_dev_slots) || return 1
  IFS=$'\t' read -r openhop_slot meshtastic_slot <<<"$slots"
  ensure_ct_usb_mount
  if ! write_udev_rule "$openhop_record" "$meshtastic_record" ||
    ! verify_alias openhop "$openhop_record" || ! verify_alias meshtastic "$meshtastic_record"; then
    remove_new_bootstrap_policy "$openhop_slot" "$meshtastic_slot"
    return 1
  fi
  "$PCT" shutdown "$ctid" --timeout 60 >/dev/null
  [[ $(ct_state) == stopped ]] || { msg_error "LXC $ctid did not stop cleanly."; remove_new_bootstrap_policy "$openhop_slot" "$meshtastic_slot"; return 1; }
  if ! "$PCT" set "$ctid" "--dev${openhop_slot}" "$(role_alias openhop),uid=0,gid=${pve_device_gid},mode=${pve_device_mode}" ||
    ! "$PCT" set "$ctid" "--dev${meshtastic_slot}" "$(role_alias meshtastic),uid=0,gid=${pve_device_gid},mode=${pve_device_mode}" ||
    ! "$PCT" start "$ctid" || ! wait_for_ct; then
    msg_error "Could not create and validate bootstrap USB grants."
    remove_new_bootstrap_policy "$openhop_slot" "$meshtastic_slot"
    return 1
  fi
  if ! write_state "$openhop_record" "$meshtastic_record" "$openhop_slot" "$meshtastic_slot" bootstrap; then
    msg_error "Could not record bootstrap USB state; removing the temporary device grants."
    remove_new_bootstrap_policy "$openhop_slot" "$meshtastic_slot"
    return 1
  fi
  msg_ok "LXC $ctid has bootstrap access to only the selected radios. Assign both radios inside the LXC, then run secure with the same selectors."
}

secure_usb() {
  local openhop_record meshtastic_record openhop_node meshtastic_node slots openhop_slot meshtastic_slot broad_rules
  local reconfiguring=0 previous_rule_backup=""
  if [[ -f "$(state_file)" ]]; then
    reconfiguring=1
    load_state
    state_matches_container_mode
    verify_pve_device_config
    if ct_is_running; then
      prepare_device_access
      state_matches_current_device_access
    else
      [[ "$state_container_mode" == privileged ]] || {
        msg_error "An unprivileged LXC must be running to revalidate its UID/GID map before reconfiguration."
        return 1
      }
      apply_state_device_access
      msg_warn "LXC $ctid is stopped; reusing its previously verified privileged plugdev mapping."
    fi
  else
    prepare_device_access
    if [[ "$container_access_mode" == privileged ]]; then
      has_usb_wildcard || {
        msg_error "The expected compatibility grant c 189:* is absent; refusing to modify an unknown USB policy."
        return 1
      }
      broad_rules=$(unexpected_broad_udev_rules || true)
      [[ -z "$broad_rules" ]] || {
        msg_error "Unexpected broad CH341 MODE=0666 udev rule(s) remain; narrow or remove them before hardening: $broad_rules"
        return 1
      }
    else
      ! has_usb_wildcard || {
        msg_error "Unprivileged LXC $ctid must not have a c 189:* USB grant."
        return 1
      }
      broad_rules=$(remaining_broad_udev_rules || true)
      [[ -z "$broad_rules" ]] || {
        msg_error "Unprivileged LXC setup refuses host CH341 MODE=0666 udev rules: $broad_rules"
        return 1
      }
    fi
  fi
  openhop_record=$(resolve_selector openhop "$openhop_selector") || return 1
  meshtastic_record=$(resolve_selector meshtastic "$meshtastic_selector") || return 1
  openhop_node=$(record_field "$openhop_record" 5)
  meshtastic_node=$(record_field "$meshtastic_record" 5)
  [[ "$openhop_node" != "$meshtastic_node" ]] || { msg_error "Both roles resolve to the same USB device."; return 1; }
  if [[ "$meshtastic_selector" == serial:* && ! "$meshtastic_selector" =~ ^serial:[A-Za-z0-9._-]{1,8}$ ]]; then
    msg_error "Meshtastic USB serial must be one to eight safe ASCII bytes."
    return 1
  fi
  if ((reconfiguring)); then
    openhop_slot=${state_openhop_dev#dev}
    meshtastic_slot=${state_meshtastic_dev#dev}
    [[ "$openhop_slot" != "$meshtastic_slot" ]] || {
      msg_error "USB state reuses one PVE devN slot for both radios."
      return 1
    }
    [[ -f "$(udev_rule_file)" ]] || {
      msg_error "Managed udev rule is missing; refusing to overwrite an incomplete hardened state."
      return 1
    }
    previous_rule_backup=$(mktemp "$(udev_rule_file).previous.XXXXXX")
    if ! cp -p -- "$(udev_rule_file)" "$previous_rule_backup"; then
      rm -f -- "$previous_rule_backup"
      return 1
    fi
  else
    slots=$(next_free_dev_slots) || return 1
    IFS=$'\t' read -r openhop_slot meshtastic_slot <<<"$slots"
  fi
  ensure_ct_usb_mount
  if ! write_udev_rule "$openhop_record" "$meshtastic_record"; then
    [[ -z "$previous_rule_backup" ]] || restore_previous_udev_rule "$previous_rule_backup"
    return 1
  fi
  if ! verify_alias openhop "$openhop_record" || ! verify_alias meshtastic "$meshtastic_record"; then
    if [[ -n "$previous_rule_backup" ]]; then
      restore_previous_udev_rule "$previous_rule_backup" || msg_warn "Could not reload the restored udev rule."
    fi
    return 1
  fi

  if ((reconfiguring)); then
    if ! restart_and_verify; then
      msg_error "Reconfiguration validation failed; restoring the previously authorized host identity."
      restore_previous_udev_rule "$previous_rule_backup" || msg_warn "Could not reload the restored udev rule."
      return 1
    fi
    rm -f -- "$previous_rule_backup"
    write_state "$openhop_record" "$meshtastic_record" "$openhop_slot" "$meshtastic_slot"
    msg_ok "LXC $ctid USB identities were reconfigured and revalidated."
    return 0
  fi

  # PVE resolves these stable udev links each time the CT starts and derives
  # exact major:minor permissions.  The aliases inside the CT are incidental;
  # libusb uses the conventional USBFS bind mount.
  "$PCT" shutdown "$ctid" --timeout 60 >/dev/null
  [[ $(ct_state) == stopped ]] || { msg_error "LXC $ctid did not stop cleanly."; return 1; }
  if ! "$PCT" set "$ctid" "--dev${openhop_slot}" "$(role_alias openhop),uid=0,gid=${pve_device_gid},mode=${pve_device_mode}" ||
    ! "$PCT" set "$ctid" "--dev${meshtastic_slot}" "$(role_alias meshtastic),uid=0,gid=${pve_device_gid},mode=${pve_device_mode}"; then
    msg_error "Could not create PVE device-scoped grants; restoring compatibility state."
    restore_pre_hardening_state "$openhop_slot" "$meshtastic_slot"
    return 1
  fi

  # Prove the aliases and application configuration work before taking away
  # the compatibility wildcard.  A failure still leaves the old permission in
  # place, avoiding a partial availability regression.
  if ! "$PCT" start "$ctid" || ! wait_for_ct || ! "$PCT" exec "$ctid" -- /usr/bin/mesh-radio verify >/dev/null ||
    ! "$PCT" shutdown "$ctid" --timeout 60 >/dev/null || [[ $(ct_state) != stopped ]]; then
    msg_error "Exact PVE device grant validation failed; restoring compatibility state."
    restore_pre_hardening_state "$openhop_slot" "$meshtastic_slot"
    return 1
  fi

  if [[ "$container_access_mode" == privileged ]]; then
    # Remove only the exact legacy lines this project/upstream installer wrote.
    # If another broad rule remains, leave the compatibility cgroup permission in
    # place and tell the operator rather than claim a partially-secure result.
    remove_legacy_broad_udev_rules
    broad_rules=$(remaining_broad_udev_rules || true)
    if [[ -n "$broad_rules" ]]; then
      msg_error "Broad CH341 MODE=0666 udev rule(s) remain; remove or narrow them before completing hardening: $broad_rules"
      return 1
    fi
    "$UDEVADM" control --reload-rules
    "$UDEVADM" trigger --subsystem-match=usb --action=change
    "$UDEVADM" settle --timeout=10

    remove_exact_line "$(ct_config)" "$WILDCARD_ALLOW"
    if has_usb_wildcard; then
      msg_error "A nonstandard c 189:* rule remains in $(ct_config); refusing incomplete hardening."
      return 1
    fi
  fi
  "$PCT" start "$ctid"
  if ! wait_for_ct || ! "$PCT" exec "$ctid" -- /usr/bin/mesh-radio verify >/dev/null; then
    msg_error "Exact PVE device permission verification failed."
    "$PCT" shutdown "$ctid" --timeout 60 >/dev/null || true
    if [[ "$container_access_mode" == privileged ]]; then
      printf '%s\n' "$WILDCARD_ALLOW" >>"$(ct_config)"
    fi
    "$PCT" start "$ctid" || true
    return 1
  fi

  write_state "$openhop_record" "$meshtastic_record" "$openhop_slot" "$meshtastic_slot"
  msg_ok "LXC $ctid now has device-scoped USB access. USBFS remains visible, but only the two assigned CH341 nodes are permitted."
}

refresh_usb() {
  load_state
  state_matches_container_mode
  [[ "$state_phase" == active ]] || {
    msg_error "LXC $ctid USB handoff is only bootstrapped. Assign both radios inside the LXC, then run secure with the original selectors."
    return 1
  }
  validate_state_devices
  verify_pve_device_config
  if ct_is_running; then
    prepare_device_access
    state_matches_current_device_access
    restart_and_verify
    msg_ok "LXC $ctid restarted with freshly resolved USB device permissions."
  else
    msg_info "LXC $ctid is stopped; PVE will resolve the stable device aliases on its next start."
  fi
}

status_usb() {
  local broad current_mode
  if [[ ! -f "$(state_file)" ]]; then
    current_mode=$(container_mode) || return 1
    if [[ "$current_mode" == unprivileged ]]; then
      msg_warn "LXC $ctid is unprivileged but has not been bootstrapped; it has no authorized radio devices yet."
    else
      msg_warn "LXC $ctid has not been hardened; its USBFS access is still managed by compatibility settings."
    fi
    return 0
  fi
  load_state
  state_matches_container_mode
  printf 'LXC %s USB handoff:\n' "$ctid"
  printf '  phase: %s\n' "$state_phase"
  printf '  container mode: %s\n' "$state_container_mode"
  printf '  openHop: %s (%s)\n' "$state_openhop_selector" "$state_openhop_id_path"
  printf '  Meshtastic: %s (%s)\n' "$state_meshtastic_selector" "$state_meshtastic_id_path"
  if validate_state_devices && verify_pve_device_config; then
    msg_ok "stable aliases and PVE device grants validate"
  else
    msg_error "USB handoff is unhealthy; do not restart the LXC until the reported identity problem is fixed."
    return 1
  fi
  broad=$(remaining_broad_udev_rules || true)
  [[ -z "$broad" ]] || { msg_error "Broad CH341 udev rule(s) remain: $broad"; return 1; }
}

list_usb() {
  local record vid pid bus address node serial port_path id_path
  printf '%-11s %-11s %-18s %s\n' 'SELECTOR' 'USBFS NODE' 'USB SERIAL' 'HOST ID_PATH'
  while IFS="$RECORD_SEPARATOR" read -r vid pid bus address node serial port_path id_path; do
    if [[ -n "$serial" ]]; then
      printf 'serial:%-4s %-11s %-18s %s\n' "$serial" "$node" "$serial" "$id_path"
    else
      printf 'port:%-6s %-11s %-18s %s\n' "$port_path" "$node" '-' "$id_path"
    fi
  done < <(discover_ch341)
}

preflight_unprivileged_usb() {
  local broad_rules
  broad_rules=$(remaining_broad_udev_rules || true)
  [[ -z "$broad_rules" ]] || {
    msg_error "Fresh unprivileged setup refuses host CH341 MODE=0666 udev rules: $broad_rules"
    return 1
  }
  msg_ok "No broad CH341 host udev rule blocks unprivileged USB setup."
}

case "$command_name" in
  list) list_usb ;;
  preflight) preflight_unprivileged_usb ;;
  status) status_usb ;;
  bootstrap) acquire_usb_lock && bootstrap_usb ;;
  secure) acquire_usb_lock && secure_usb ;;
  refresh) acquire_usb_lock && refresh_usb ;;
esac
