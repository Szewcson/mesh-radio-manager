# Prototype migration audit

The reference branch is `/home/user/proj/openhop-repeater-meshtastic`,
`feature/meshtasticd-proxmox` (13 commits beyond `upstream/dev`).  It remains
unchanged as historical/prototype work; this project does not consume it at
runtime.

| Prototype change | Disposition |
| --- | --- |
| Sysfs USB discovery, CH341 identification, locking/atomic YAML writes | Reused with adaptation. Persistent identity is now serial, then controller/port topology, then a singleton-only unidentified fallback. |
| Meshtastic profiles, USBFS isolation concept, package/backup diagnostics | Reused with adaptation, outside the openHop tree. |
| Meshtastic API endpoints and injected pages | Removed. The manager has its own optional service/UI. |
| Modified `openhop-repeater.service`, `repeater.main`, `manage.sh`, `pyproject.toml` | Removed. A documented systemd drop-in is the only openHop integration. |
| Proxmox installer and copied `openhop-update` | Obsolete. Official openHop install/update remain upstream-owned. |
| Fork web config persistence and account/auth changes | OpenHop-specific; not migrated. They should be proposed upstream separately if desired. |

Migration plan:

1. Install official openHop first, unchanged.
2. Install this repository next to it and create only manager-owned files and
   `/etc/systemd/system/*.d` drop-ins.
3. Assign one radio to each service and validate before either daemon starts.
4. Use upstream's openHop updater normally; `mesh-radio verify` reports a dirty
   upstream checkout rather than attempting to repair it.
