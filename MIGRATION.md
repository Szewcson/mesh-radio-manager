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

## Privileged-to-unprivileged deployment transition

This project intentionally does **not** convert an existing privileged CT. A
privilege conversion changes user-namespace ownership semantics and USB access
at the same time, which is not safe to automate around a live radio service.
The supported transition is a fresh deployment:

1. Retire the prior CT only when its configuration and backups are no longer
   needed. Its host-wide CH341 `MODE="0666"` rule must also be removed, or its
   existing device-scoped hardening completed, before the new deployment can
   bootstrap.
2. Create a new CT with `scripts/proxmox-install.sh --unprivileged`. The
   temporary upstream installer copy is checked against exact creation and USB
   section markers before its privileged USB policy is removed.
3. Select the two radios in the installer's host-side menu. The installer
   bootstraps them, passes the two selectors into `mesh-radio assign` inside
   the new CT, verifies them, and finalizes the grants. It maps the new CT's
   `plugdev` GID through its live GID map at both stages.
4. Use `--manual-radio-configuration` only when you want the installer to stop
   after the narrow bootstrap grant; then assign inside the CT and run
   `mesh-radio-pve --secure-usb` with the displayed selectors yourself.

If any identity, user/group map, or permission validation fails, the new CT
remains unprivileged and the helper fails closed. Existing CT state is neither
edited nor used as input to the new deployment.
