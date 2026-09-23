#!/usr/bin/env bash
# Proxmox-host lifecycle helper for Mesh Radio Manager LXCs.
#
# It deliberately uses this project's tag rather than Community Scripts tags:
# this is an independent project and must not masquerade as a catalogue entry.
set -Eeuo pipefail

MANAGER_TAG="mesh-radio-manager"
HOST_LOCK_DIR=/run/mesh-radio-manager
HOST_LOCK_FILE="$HOST_LOCK_DIR/proxmox-host-lifecycle.lock"
# An intentional, documented non-error result for a template.  Do not report a
# template as updated: Proxmox templates are not runnable containers.
SKIPPED_EXIT=75

RD="\033[01;31m"
GN="\033[1;92m"
YW="\033[33m"
BL="\033[36m"
CL="\033[m"

msg_info() { echo -e " ${BL}ℹ${CL} $*"; }
msg_ok() { echo -e " ${GN}✓${CL} $*"; }
msg_warn() { echo -e " ${YW}⚠${CL} $*"; }
msg_error() { echo -e " ${RD}✗${CL} $*" >&2; }

usage() {
  cat <<'EOF'
Usage:
  mesh-radio-pve [--ctid CTID]
  mesh-radio-pve --ctid CTID --update --yes [--backup --backup-storage STORAGE]
  mesh-radio-pve --all --update --yes [--backup --backup-storage STORAGE] [--continue-on-error]
  mesh-radio-pve (--ctid CTID | --all) --dry-run
  mesh-radio-pve --doctor
  mesh-radio-pve --prune --yes

Only LXCs tagged mesh-radio-manager are selected. --backup takes a Proxmox
snapshot before each update and restores that exact backup if its update fails.
--yes is required for noninteractive updates. --dry-run never changes a CT.
EOF
}

[[ $EUID -eq 0 ]] || { msg_error "Run this from the Proxmox host as root."; exit 1; }
command -v pct >/dev/null || { msg_error "Proxmox pct command not found."; exit 1; }

ctid=""
update_requested=0
update_all=0
assume_yes=0
backup_requested=0
backup_storage=""
continue_on_error=0
dry_run=0
doctor_requested=0
prune_requested=0
while (($#)); do
  case "$1" in
    --ctid)
      shift
      [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
      ctid=$1
      ;;
    --all) update_all=1 ;;
    --update) update_requested=1 ;;
    --yes) assume_yes=1 ;;
    --backup) backup_requested=1 ;;
    --backup-storage)
      shift
      [[ $# -gt 0 && "$1" =~ ^[A-Za-z0-9._-]+$ ]] || { usage >&2; exit 2; }
      backup_storage=$1
      ;;
    --continue-on-error) continue_on_error=1 ;;
    --dry-run) dry_run=1 ;;
    --doctor) doctor_requested=1 ;;
    --prune) prune_requested=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if ((doctor_requested || prune_requested)); then
  if [[ -n "$ctid" || $update_all -eq 1 || $update_requested -eq 1 || $backup_requested -eq 1 || $dry_run -eq 1 || $continue_on_error -eq 1 ]]; then
    msg_error "--doctor and --prune cannot be combined with CT update options."
    exit 2
  fi
  if ((doctor_requested && prune_requested)); then
    msg_error "Choose either --doctor or --prune."
    exit 2
  fi
  if ((prune_requested && ! assume_yes)); then
    msg_error "--prune removes the host helper and requires --yes."
    exit 2
  fi
elif ((dry_run)); then
  (( ! update_requested && ! backup_requested && ! continue_on_error && ! assume_yes )) || {
    msg_error "--dry-run cannot be combined with update, backup, continue, or --yes options."
    exit 2
  }
  [[ -n "$ctid" || $update_all -eq 1 ]] || { msg_error "--dry-run requires --ctid or --all."; exit 2; }
elif ((update_requested)); then
  ((assume_yes)) || { msg_error "Noninteractive update requires --yes."; exit 2; }
  [[ -n "$ctid" || $update_all -eq 1 ]] || { msg_error "--update requires --ctid or --all."; exit 2; }
  if ((backup_requested)) && [[ -z "$backup_storage" ]]; then
    msg_error "Noninteractive backup requires --backup-storage."
    exit 2
  fi
elif [[ -n "$ctid" || $update_all -eq 1 || $assume_yes -eq 1 || $backup_requested -eq 1 || -n "$backup_storage" || $continue_on_error -eq 1 ]]; then
  msg_error "CT selection, backup, and --yes options require --update or --dry-run."
  exit 2
fi
if ((update_all)) && [[ -n "$ctid" ]]; then
  msg_error "Choose either --ctid or --all."
  exit 2
fi

ct_exists() {
  pct status "$1" >/dev/null 2>&1
}

ct_state() {
  local status
  status=$(pct status "$1" 2>/dev/null) || return 1
  awk '{print $2}' <<<"$status"
}

ct_is_managed() {
  local config tags
  config=$(pct config "$1" 2>/dev/null) || return 2
  tags=$(awk -F': ' '$1 == "tags" {print $2; exit}' <<<"$config")
  [[ ";${tags};" == *";${MANAGER_TAG};"* ]]
}

ct_is_template() {
  local config
  config=$(pct config "$1" 2>/dev/null) || return 2
  awk '$1 == "template:" && $2 == "1" {found=1} END {exit !found}' <<<"$config"
}

managed_ctids() {
  local candidates candidate check_status
  candidates=$(pct list) || {
    msg_error "Cannot enumerate Proxmox LXCs."
    return 1
  }
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if ct_is_managed "$candidate"; then
      printf '%s\n' "$candidate"
    else
      check_status=$?
      if ((check_status != 1)); then
        msg_error "Cannot inspect tags for LXC ${candidate}; refusing an incomplete managed-LXC scan."
        return 1
      fi
    fi
  done < <(awk 'NR > 1 {print $1}' <<<"$candidates")
}

acquire_host_lock() {
  command -v flock >/dev/null || { msg_error "flock is required on the Proxmox host."; return 1; }
  install -d -m 0750 "$HOST_LOCK_DIR"
  exec 9>"$HOST_LOCK_FILE"
  flock -n 9 || { msg_error "Another Mesh Radio Manager host install or update is running."; return 1; }
}

backup_storages() {
  awk '
    /^[a-z]+:/ {
      if (name != "" && (has_backup || (!has_content && type == "dir"))) print name
      split($0, fields, ":")
      type = fields[1]
      name = fields[2]
      gsub(/^[ \t]+|[ \t]+$/, "", name)
      has_content = 0
      has_backup = 0
      next
    }
    /^[ \t]*content/ {
      has_content = 1
      if ($0 ~ /backup/) has_backup = 1
    }
    END {
      if (name != "" && (has_backup || (!has_content && type == "dir"))) print name
    }
  ' /etc/pve/storage.cfg
}

storage_supports_backup() {
  local storage=$1 candidate
  while IFS= read -r candidate; do
    [[ "$candidate" == "$storage" ]] && return 0
  done < <(backup_storages)
  return 1
}

select_backup_storage() {
  local -a choices=() menu=()
  local choice
  mapfile -t choices < <(backup_storages)
  ((${#choices[@]})) || { msg_error "No Proxmox storage with backup content is configured."; return 1; }
  if [[ -n "$backup_storage" ]]; then
    storage_supports_backup "$backup_storage" || {
      msg_error "Backup storage '$backup_storage' does not support Proxmox backups."
      return 1
    }
    return 0
  fi
  if ((${#choices[@]} == 1)); then
    backup_storage=${choices[0]}
    return 0
  fi
  if command -v whiptail >/dev/null; then
    for choice in "${choices[@]}"; do
      menu+=("$choice" "Proxmox backup storage")
    done
    backup_storage=$(whiptail --title "Mesh Radio Manager backup" \
      --menu "Select backup storage:" 16 70 8 "${menu[@]}" 3>&1 1>&2 2>&3) || return 1
  else
    PS3="Backup storage: "
    select choice in "${choices[@]}"; do
      [[ -n "$choice" ]] && { backup_storage=$choice; break; }
      msg_warn "Select one of the listed storage names."
    done
  fi
  storage_supports_backup "$backup_storage"
}

list_ct_backups() {
  local target=$1
  pvesm list "$backup_storage" 2>/dev/null |
    awk -v ctid="$target" '$1 ~ "vzdump-lxc-" ctid "-" {print $1}' |
    sort -u
}

declare -A backup_by_ct=()
declare -a update_results=()

backup_ct() {
  local target=$1 before after backup
  before=$(list_ct_backups "$target") || {
    msg_error "Cannot list existing backups for LXC ${target} on ${backup_storage}."
    return 1
  }
  msg_info "Creating snapshot backup for LXC ${target} on ${backup_storage}"
  vzdump "$target" --mode snapshot --compress zstd --storage "$backup_storage" \
    --notes-template '{{guestname}} - Mesh Radio Manager pre-update' || return 1
  after=$(list_ct_backups "$target") || {
    msg_error "Backup completed, but cannot list backups to identify its volume."
    return 1
  }
  backup=$(comm -13 <(printf '%s\n' "$before" | sort -u) <(printf '%s\n' "$after" | sort -u) | tail -n 1)
  [[ -n "$backup" ]] || {
    msg_error "Proxmox reported a successful backup, but its new backup volume could not be identified."
    return 1
  }
  backup_by_ct["$target"]=$backup
  msg_ok "Backup created: ${backup}"
}

restore_ct() {
  local target=$1 backup rootfs_storage config state
  backup=${backup_by_ct["$target"]:-}
  [[ -n "$backup" ]] || { msg_error "No rollback backup is recorded for LXC ${target}."; return 1; }
  config=$(pct config "$target") || {
    msg_error "Cannot read configuration for LXC ${target} before rollback."
    return 1
  }
  rootfs_storage=$(awk -F '[:,]' '$1 == "rootfs" {print $2; exit}' <<<"$config")
  [[ -n "$rootfs_storage" ]] || { msg_error "Cannot determine rootfs storage for LXC ${target}."; return 1; }
  msg_warn "Restoring LXC ${target} from ${backup} after failed update"
  state=$(ct_state "$target") || {
    msg_error "Cannot determine LXC ${target} state before rollback."
    return 1
  }
  if [[ "$state" != stopped ]]; then
    pct stop "$target" >/dev/null || {
      msg_error "Could not stop LXC ${target} before rollback."
      return 1
    }
  fi
  state=$(ct_state "$target") || return 1
  [[ "$state" == stopped ]] || {
    msg_error "LXC ${target} is still ${state}; refusing a forced rollback."
    return 1
  }
  pct restore "$target" "$backup" --storage "$rootfs_storage" --force || {
    msg_error "Proxmox rollback failed for LXC ${target}."
    return 1
  }
}

wait_for_ct() {
  local target=$1 attempt=0
  while ((attempt < 30)); do
    pct exec "$target" -- true >/dev/null 2>&1 && return 0
    sleep 1
    ((attempt += 1))
  done
  msg_error "LXC ${target} did not become ready within 30 seconds."
  return 1
}

restore_initial_state() {
  local target=$1 initial_state current_state
  current_state=$(ct_state "$target") || {
    msg_error "Cannot determine current state of LXC ${target}."
    return 1
  }
  case "$initial_state" in
    stopped)
      [[ "$current_state" == stopped ]] && return 0
      msg_info "Returning LXC ${target} to its original stopped state"
      pct shutdown "$target" --timeout 60 || {
        msg_error "Could not shut down LXC ${target}."
        return 1
      }
      current_state=$(ct_state "$target") || return 1
      [[ "$current_state" == stopped ]] || {
        msg_error "LXC ${target} did not stop cleanly; leaving it running for inspection."
        return 1
      }
      ;;
    running)
      if [[ "$current_state" != running ]]; then
        msg_info "Returning LXC ${target} to its original running state"
        pct start "$target" || {
          msg_error "Could not start LXC ${target}."
          return 1
        }
        wait_for_ct "$target" || return 1
      fi
      ;;
    *)
      msg_error "Unexpected original state for LXC ${target}: ${initial_state}"
      return 1
      ;;
  esac
}

validate_update_target() {
  local target=$1 check_status
  ct_exists "$target" || { msg_error "LXC ${target} does not exist."; return 2; }
  if ct_is_managed "$target"; then
    :
  else
    check_status=$?
    if ((check_status == 1)); then
      msg_error "LXC ${target} is not tagged ${MANAGER_TAG}."
      return 2
    fi
    msg_error "Cannot inspect tags for LXC ${target}."
    return 1
  fi
  if ct_is_template "$target"; then
    msg_warn "Skipping template LXC ${target}."
    return "$SKIPPED_EXIT"
  else
    check_status=$?
  fi
  if ((check_status != 1)); then
    msg_error "Cannot inspect template status for LXC ${target}."
    return 1
  fi
  return 0
}

dry_run_ct() {
  local target=$1 state target_status
  if validate_update_target "$target"; then
    :
  else
    target_status=$?
    return "$target_status"
  fi
  state=$(ct_state "$target") || { msg_error "Cannot determine LXC ${target} state."; return 1; }
  printf 'LXC %s: state=%s; manager status follows\n' "$target" "$state"
  if [[ "$state" == running ]]; then
    pct exec "$target" -- /usr/bin/mesh-radio status
  else
    msg_warn "LXC ${target} is stopped; no service query was run."
  fi
}

update_ct() {
  local target=$1 initial_state current_state rollback_failed=0 state_restore_failed=0 target_status
  if validate_update_target "$target"; then
    :
  else
    target_status=$?
    return "$target_status"
  fi
  initial_state=$(ct_state "$target") || { msg_error "Cannot determine LXC ${target} state."; return 1; }
  [[ "$initial_state" == running || "$initial_state" == stopped ]] || {
    msg_error "LXC ${target} is in unsupported state '${initial_state}'."
    return 1
  }
  if ((backup_requested)); then
    backup_ct "$target" || return 1
  fi
  if [[ "$initial_state" == stopped ]]; then
    msg_info "Starting stopped LXC ${target} for update"
    pct start "$target" || {
      msg_error "Could not start LXC ${target} for update."
      return 1
    }
    wait_for_ct "$target" || return 1
  fi
  msg_info "Updating LXC ${target}"
  if pct exec "$target" -- env PYMC_SILENT=1 /usr/bin/mesh-radio update; then
    restore_initial_state "$target" "$initial_state" || return 1
    return 0
  fi
  msg_error "Update failed for LXC ${target}"
  if ((backup_requested)); then
    restore_ct "$target" || rollback_failed=1
  fi
  restore_initial_state "$target" "$initial_state" || state_restore_failed=1
  current_state=$(ct_state "$target") || state_restore_failed=1
  [[ "$current_state" == "$initial_state" ]] || {
    msg_error "LXC ${target} could not be returned to its original state."
    state_restore_failed=1
  }
  ((rollback_failed == 0 && state_restore_failed == 0)) || return 1
  return 1
}

run_cts() {
  local target action_status exit_code=0
  local -a targets=("$@")
  ((${#targets[@]})) || { msg_error "No managed LXCs were selected."; return 1; }
  acquire_host_lock || return 1
  for target in "${targets[@]}"; do
    if ((dry_run)); then
      if dry_run_ct "$target"; then
        update_results+=("${target}|DRY-RUN|No changes")
      else
        action_status=$?
        if ((action_status == SKIPPED_EXIT)); then
          update_results+=("${target}|SKIPPED|Template LXC")
        else
          exit_code=1
          update_results+=("${target}|FAILED|Dry-run query failed")
        fi
      fi
    elif update_ct "$target"; then
      update_results+=("${target}|UPDATED|Completed")
    else
      action_status=$?
      if ((action_status == SKIPPED_EXIT)); then
        update_results+=("${target}|SKIPPED|Template LXC")
      else
        exit_code=1
        update_results+=("${target}|FAILED|See task output above")
        ((continue_on_error)) || break
      fi
    fi
  done
  printf '\n%-8s %-10s %s\n' "CTID" "RESULT" "DETAIL"
  for target in "${update_results[@]}"; do
    IFS='|' read -r ctid result detail <<<"$target"
    printf '%-8s %-10s %s\n' "$ctid" "$result" "$detail"
  done
  return "$exit_code"
}

doctor() {
  local -a targets=()
  local target state targets_text
  targets_text=$(managed_ctids) || return 1
  if [[ -n "$targets_text" ]]; then
    mapfile -t targets <<<"$targets_text"
  fi
  if ((${#targets[@]} == 0)); then
    msg_warn "No LXCs are tagged ${MANAGER_TAG}."
    echo "Run mesh-radio-pve --prune --yes to remove this unused host helper."
    return 0
  fi
  msg_ok "Host helper manages ${#targets[@]} LXC(s) tagged ${MANAGER_TAG}."
  for target in "${targets[@]}"; do
    state=$(ct_state "$target") || {
      msg_error "Cannot determine state of LXC ${target}."
      return 1
    }
    printf '  LXC %s: %s\n' "$target" "$state"
  done
}

prune() {
  local helper_path
  local -a targets=()
  local targets_text
  acquire_host_lock || return 1
  targets_text=$(managed_ctids) || return 1
  if [[ -n "$targets_text" ]]; then
    mapfile -t targets <<<"$targets_text"
  fi
  if ((${#targets[@]})); then
    msg_error "Managed LXCs still exist; refusing to remove the host helper."
    return 1
  fi
  helper_path=$(readlink -f "$0" 2>/dev/null || true)
  [[ "$helper_path" == /usr/local/sbin/mesh-radio-pve ]] || {
    msg_error "Refusing to remove a helper that is not installed at /usr/local/sbin/mesh-radio-pve."
    return 1
  }
  rm -f -- "$helper_path"
  msg_ok "Removed unused host helper: ${helper_path}"
}

if ((doctor_requested)); then
  doctor
  exit $?
fi
if ((prune_requested)); then
  prune
  exit $?
fi

if ((update_all)); then
  selected_text=$(managed_ctids) || exit 1
  if [[ -n "$selected_text" ]]; then
    mapfile -t selected_ctids <<<"$selected_text"
  else
    selected_ctids=()
  fi
else
  selected_ctids=("$ctid")
fi

if ((dry_run || update_requested)); then
  run_cts "${selected_ctids[@]}"
  exit $?
fi

pct list
read -r -p "Mesh Radio Manager CTID: " ctid
if ! [[ "$ctid" =~ ^[0-9]+$ ]] || ! pct status "$ctid" >/dev/null 2>&1; then
  msg_error "Invalid CTID: $ctid"
  exit 2
fi
ct_is_managed "$ctid" || {
  msg_error "LXC $ctid is not tagged ${MANAGER_TAG}; use the managed installer first."
  exit 2
}

run_in_lxc() {
  pct exec "$ctid" -- "$@"
}

while :; do
  clear
  echo "╔══════════════════════════════════════════════╗"
  echo "║     Mesh Radio Manager — Proxmox Control     ║"
  echo "╚══════════════════════════════════════════════╝"
  echo "  CTID: $ctid ($(ct_state "$ctid"))"
  echo "  1) Status"
  echo "  2) Radios and assignments"
  echo "  3) Verify USB ownership"
  echo "  4) Diagnostics"
  echo "  5) Logs"
  echo "  6) Restart radio services"
  echo "  7) Update everything"
  echo "  8) Enter LXC shell"
  echo "  0) Exit"
  read -r -p " Select: " choice
  case "$choice" in
    1) run_in_lxc /usr/bin/mesh-radio status ;;
    2) run_in_lxc /usr/bin/mesh-radio radios ;;
    3) run_in_lxc /usr/bin/mesh-radio verify ;;
    4) run_in_lxc /usr/bin/mesh-radio diagnose ;;
    5)
      read -r -p " Service (openhop/meshtastic): " service
      case "$service" in openhop|meshtastic) run_in_lxc /usr/bin/mesh-radio logs "$service" ;; *) msg_error "Unknown service" ;; esac
      ;;
    6)
      run_in_lxc systemctl restart meshtasticd
      run_in_lxc systemctl restart openhop-repeater
      ;;
    7)
      read -r -p "Run official openHop + manager + meshtasticd update? [y/N]: " answer
      if [[ "$answer" =~ ^[Yy]$ ]]; then
        backup_requested=0
        backup_storage=""
        read -r -p "Create a snapshot backup and roll back on failure? [y/N]: " backup_answer
        if [[ "$backup_answer" =~ ^[Yy]$ ]]; then
          backup_requested=1
          if ! select_backup_storage; then
            backup_requested=0
            msg_error "Update cancelled: no usable backup storage selected."
            read -r -p "Press Enter to continue..." _
            continue
          fi
        fi
        dry_run=0
        continue_on_error=0
        run_cts "$ctid" || true
      fi
      ;;
    8) pct enter "$ctid" ;;
    0) exit 0 ;;
    *) msg_error "Unknown selection" ;;
  esac
  read -r -p "Press Enter to continue..." _
done
