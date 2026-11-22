# CPZ-Alpine v0.22.3 — LoRa hat support (Cap LoRa-1262)

This release disables on-board Bluetooth by default and routes the PL011
hardware UART to GPIO 14/15 so the Cap LoRa-1262 hat (SX1262, serial AT
commands) works on `/dev/ttyAMA0` at 115200 baud out of the box.

## What's new

**LoRa hat serial port on GPIO 14/15**

- `disable-bt` overlay frees the PL011 UART from the on-board Bluetooth
  chip (Murata Type-1YN CYW4343A2).
- `uart0` overlay routes the PL011 to GPIO 14 (TXD) and GPIO 15 (RXD),
  giving a clean hardware UART at 115200 baud with a stable 48 MHz clock —
  no baud-rate drift.
- The Cap LoRa-1262 hat (and any serial device wired to GPIO 14/15) now
  works immediately: open `/dev/ttyAMA0`, configure `115200 8N1`, and
  send AT commands.

**Why miniuart-bt didn't work**

The obvious alternative — `dtoverlay=miniuart-bt` (Bluetooth on the
mini-UART, PL011 on GPIO 14/15) — was tested on hardware and failed.
The Broadcom BT chip on this board does not respond through the
mini-UART: HCI tx timeouts and frame reassembly errors regardless of
core clock speed. The pinctrl was correct (GPIO 30–33 in ALT5), but
the chip is hard-wired to the PL011 internally. This is a hardware
constraint of the Murata module.

**Known side-effect: Bluetooth is off by default**

Bluetooth and LoRa share the same PL011 controller — only one set of
pins can be active at a time. This release defaults to LoRa (GPIO 14/15).
A future launcher toggle will let users switch between the two modes
(with a required reboot — UART routing is set at boot time by the device
tree). For now, if you need Bluetooth:
1. Remove or comment out `dtoverlay=disable-bt` and `dtoverlay=uart0`
   from `/boot/config.txt`
2. Reboot

## Known issues

- Bluetooth is disabled by default (hardware constraint — see above).
- The Bluetooth/LoRa toggle is documented but not yet implemented as a
  launcher page (planned for a future release).
- All known issues from v0.22.2 still apply (Compass calibration not
  verified on hardware, card-pull-during-save can lose the last snapshot).

## Untested / needs a hardware pass

- Cap LoRa-1262 hat: the UART is verified at the pin level (GPIO 14/15
  ALT0, 48 MHz PL011 clock, `/dev/ttyAMA0` writable), but an actual
  SX1262 AT-command exchange with a real LoRa peer has not been done
  on this build.
- Bluetooth re-enable path: removing the two overlays and rebooting
  should restore `hci0`, but this hasn't been re-tested on this image.

## Flash

Download the ZIP, verify the SHA-256, then:

```sh
sudo ./flash-cpz.sh /dev/mmcblk0     # or /dev/sdX
```

Watch for `snapshot rewritten: N bytes (backup: N bytes)` — the numbers
must match; any `ERROR` line means the flash was aborted and your pre-flash
copy is safe in `cpz-cfg-backup-*`.