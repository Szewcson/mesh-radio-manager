# shellcheck shell=sh
# Shown only in interactive LXC shells; it contains no credentials or secrets.
case $- in
  *i*) ;;
  *) return ;;
esac

mesh_radio_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
printf '\n'
printf '  Mesh Radio Manager LXC\n'
printf '  openHop UI: http://%s:8000\n' "${mesh_radio_ip:-<LXC-IP>}"
printf '  Manager:    mesh-radio-menu\n'
printf '  Update all: mesh-radio update\n\n'
unset mesh_radio_ip
