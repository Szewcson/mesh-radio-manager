# Mesh Radio Manager

Mesh Radio Manager is an independent companion project for managing multiple
Linux USB LoRa radios and running services such as openHop/MeshCore and
Meshtastic side-by-side.

It is **not** an openHop fork and does not redistribute openHop. Install
openHop with the official instructions from
[`openhop-dev/openhop_repeater`](https://github.com/openhop-dev/openhop_repeater)
first; openHop updates remain managed by upstream.

```text
HAOS VM
  |
  +-- MeshCore integration -- TCP 5000 -- openHop -- PineDio
  |
  +-- Meshtastic integration - TCP 4403 -- meshtasticd -- MeshTadpole

Debian LXC
  |
  +-- upstream openHop (/root/openhop-repeater, untouched)
  +-- meshtasticd
  +-- Mesh Radio Manager -- USB assignment and safety checks
```

## Install

Create the LXC with the official openHop installer. Inside that LXC, clone or
download a release of this project, then run:

```bash
sudo ./install.sh
```

The installer refuses to recreate openHop when it is absent. It preserves
`/etc/openhop_repeater/config.yaml`, writes manager state below
`/etc/mesh-radio-manager`, `/var/lib/mesh-radio-manager`, and
`/var/log/mesh-radio-manager`, and installs systemd **drop-ins** only. It does
not change `/root/openhop-repeater` or `/opt/openhop_repeater`.

For a published release the same installer can be used as:

```bash
curl -fsSL https://github.com/Szewcson/mesh-radio-manager/releases/latest/download/install.sh | sudo bash
```

The release installer downloads this project only; it never vendors openHop.

`./install.sh --install-meshtastic --channel beta` optionally configures the
current Meshtastic upstream package channel. It never changes RF region, power,
or PSKs.

## First deployment

```bash
sudo mesh-radio radios
# Choose the displayed selector (USB serial is preferred).
sudo mesh-radio assign openhop --device path:4-2 --profile pinedio
sudo mesh-radio assign meshtastic --device serial:12345678 --profile meshtadpole
sudo mesh-radio verify
sudo mesh-radio meshtastic configure
sudo mesh-radio meshtastic restart
sudo mesh-radio openhop restart
```

`assign` refuses live reassignment while either radio daemon runs. It also
rejects any same-radio assignment. A serial is persistent; otherwise the
manager uses stable controller/port topology. If neither exists, it accepts
the assignment only while exactly one matching, no-serial radio is present.
USB bus/address is shown for diagnosis only and is never saved as identity.

The optional status UI is deliberately loopback-only by default:

```bash
sudo mesh-radio web enable
# tunnel or change /etc/mesh-radio-manager/config.yaml host deliberately
```

It is a read-only diagnostics dashboard in this initial release; the CLI is
the authenticated administrator interface for assignments and service control.
For vetted non-hardware Meshtastic settings (such as settings documented by
the installed meshtasticd version), use
`mesh-radio meshtastic configure --advanced-file settings.yaml`. A `Lora`
block is rejected because GPIO and USB ownership must remain attached to the
radio assignment. Region/power are deliberately not silently set by this
project; configure them through the Meshtastic node/API after choosing the
legal local region.

## Operations

```bash
mesh-radio status
mesh-radio radios
mesh-radio verify
mesh-radio diagnose > mesh-radio-diagnose.txt
mesh-radio logs openhop
mesh-radio logs meshtastic
mesh-radio meshtastic upgrade        # displays versions, backs up config, asks
mesh-radio update                    # updates this project only
mesh-radio update --meshtastic --yes # updates this project, then meshtasticd
```

Update openHop with its official upstream command. Before and after updating,
run `mesh-radio verify`; it reports the exact upstream branch, commit, and
whether `/root/openhop-repeater` is clean. Mesh Radio Manager makes no commit
and no source change in that checkout.

`mesh-radio update --meshtastic` is a preflight only: it shows the installed
and candidate meshtasticd versions and stops. Add `--yes` to confirm. The
meshtasticd upgrade backs up `/etc/meshtasticd/config.yaml` under
`/var/lib/mesh-radio-manager/backups` before calling apt. This is deliberately
separate from the official openHop update command.

To remove only this project:

```bash
sudo ./uninstall.sh
```

This removes manager-owned files/drop-ins and leaves openHop, meshtasticd, and
their configurations in place.

## Systemd design and limitation

`20-mesh-radio-manager.conf` adds an `ExecStartPre` that validates assignments
and generates `/run/mesh-radio-manager/openhop-config.yaml`; it then replaces
only the service command with the same public upstream module and points it at
that ephemeral copy. The vendor unit and openHop configuration remain
untouched. The installer verifies that the known upstream unit command is
present before enabling this integration. If upstream changes its unit
contract, disable the drop-in and update this manager before continuing.

The meshtasticd drop-in starts a manager wrapper in a private mount namespace.
The wrapper validates exclusive assignment, generates manager-owned effective
YAML, and exposes only the assigned USBFS node when a serial selector cannot
be passed to meshtasticd. This is intentionally not based on startup order.

Meshtastic hardware fields are limited to profiles verified against current
upstream Meshtastic configuration sources. Generic CH341/SX1262 needs explicit
verified pin mapping. Meshtastic region remains node configuration and is not
silently selected by this project.

The MeshTadpole profile is taken from Meshtastic's
[`lora-usb-meshtoad-e22.yaml`](https://raw.githubusercontent.com/meshtastic/firmware/develop/bin/config.d/lora-usb-meshtoad-e22.yaml),
including its optional `USB_Serialnum` multi-radio selector. PineDio uses the
current upstream `lora-pinedio-usb-sx1262.yaml` profile, which upstream marks
as **deprecated**; it remains available for existing hardware but should be
validated carefully after every Meshtastic update.
