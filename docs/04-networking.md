# 04 — Networking: USB + wired + wireless

Design for all three network planes plus Bluetooth. Implementation lands in
[Stage 05](../stages/stage-05-networking.md); chip identities come from the
Stage 01 harvest (docs/01 TBD items).

## 1. USB host stack

- **Controller:** BCM2837's DWC2 in **host** mode (`dr_mode=host` comes from
  the harvested DT — M5's DTB already sets it; verify, don't guess).
- **Hub:** the on-board USB hub (part of the ethernet chip on Pi-family
  boards) enumerates automatically; `lsusb` shows the topology.
- **Which USB-C is data:** determined empirically in S01 (keyboard in each
  port + `dmesg`). The USB-A port is host, documented in docs/01 row 10.
- **Modules:** `dwc2` (likely built-in), `usb-storage`, `uas`, `usbhid`,
  plus the ethernet driver below (it's USB-attached too).
- **Automount:** eudev rule → small mount helper for `/dev/sd*`/`/dev/sda1`
  under `/media/usb*`, mounted `noatime`, `sync` off (SD-friendly `noatime`
  only; we don't fear unclean unplugs as much as we fear SD corruption).
- **Acceptance:** USB flash drive mounts read/write; USB keyboard types into
  the console (and into the desktop session later).

## 2. Wired Ethernet (10/100)

The CPZ has no native MAC — Ethernet is **USB-attached**. Driver shortlist
until Stage 01 pins the chip:

| Chip (suspect) | `lsusb` ID | Driver | Typical for |
|---|---|---|---|
| LAN9514 hub+eth | `0424:9514` | `smsc95xx` | Pi 3B pattern — **most likely** |
| RTL8152/8153 | `0bda:815x` | `r8152` | common on gadget boards |
| AX88772 | `0b95:7720` | `asix` | common on SBCs |
| LAN7800 | `0424:7800` | `lan78xx` | Pi 3B+/CM3+ pattern |

All of these are in-tree; enable whichever the harvest names (and keep the
others as modules — they cost nothing unloaded).

`/etc/network/interfaces` (ifupdown-ng):

```
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp      # busybox udhcpc
# static fallback example (commented):
# iface eth0 inet static
#   address 192.168.23.42/24
#   gateway 192.168.23.1
```

`udhcpc` (BusyBox) with its default script is enough — no dhcpcd daemon.

## 3. Wi-Fi (2.4 GHz b/g/n)

- **Driver:** `brcmfmac` (CM0 is Zero-2W-class; expect the `43436` firmware
  family, `43430` as alternate — the harvest decides).
- **Firmware:** copy the *entire* harvested `/lib/firmware/brcm/` — the
  `.bin` image, the **board nvram `.txt`** (board-specific, never generic),
  and the BT `.hcd`. This is the one case where "just install
  linux-firmware" is not good enough.
- **Supplicant:** `wpa_supplicant` with `nl80211`; config at
  `/etc/wpa_supplicant/wpa_supplicant.conf`:

```
country=BG
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="ExampleNet"
    psk="change-me"
    key_mgmt=WPA-PSK
    scan_ssid=1
}
```

- **OpenRC:** `rc-update add wpa_supplicant boot`, and `wlan0` stanza in
  `interfaces` (`auto wlan0` / `iface wlan0 inet dhcp`), or driven by
  `wpa_cli` action scripts if we prefer manual control on a pocket device.
- **Regdom:** `country=BG` above + `cfg80211.ieee80211_regdom=BG` on the
  cmdline keeps tx power legal (set your own country).
- **Power:** `iw dev wlan0 set power_save on` in a local.d hook — part of
  the R9 power strategy; measured drain impact recorded in S06.
- **Acceptance:** joins WPA2-PSK at boot, `iw dev wlan0 link` shows the AP,
  ping out, powersave on.

## 4. Bluetooth (bonus, but planned — "full hardware support")

- HCI over UART (Pi-family pattern): needs the `.hcd` firmware (harvested)
  loaded at attach time.
- Bring-up: `hciattach` (from bluez) against the UART, or the modern
  `btattach`; whichever the stock image uses (check
  `harvest/logs/units.txt` + `hci.txt`) gets translated into an OpenRC unit
  `cpz-bt`.
- Userland: `bluez` + `bluetoothctl`; no desktop applet ever.
- **Acceptance:** `hciconfig hci0 up`, `bluetoothctl scan on` finds a
  device; record RAM cost (target ≤ 8 MB).

## 5. Optional extras (nice-to-have, off the critical path)

- **USB gadget mode on the data USB-C:** the DWC2 is an OTG controller —
  `g_ether`/libcomposite gives USB-CDC networking straight to a laptop
  (zero-config debugging/SSH without Wi-Fi). Requires a DT mode switch
  (`dr_mode=peripheral` or `otg` + a script toggling via configfs) —
  **documented but deferred** until S09 polish; do not break host mode for it.
- **mDNS (`cpz.local`):** `avahi` if it fits the RAM budget after S09
  measurements; otherwise a tiny `mdnsd` or nothing (IP over USB/serial is
  the fallback).

## 6. Boot-time dependency order

```
udev (sysinit) → hwclock → networking (ifupdown-ng)
                                  ├─ eth0: udhcpc
                                  └─ wlan0: needs wpa_supplicant (boot) first
```

`wpa_supplicant` before `networking` avoids the classic race; both are
OpenRC `need`/`use` links away. Verified by clean cold-boot test (S05
acceptance), not just warm reboots.

## 7. Acceptance summary (mirror of Stage 05 gate)

- [ ] eth0: DHCP lease + ping on cold boot
- [ ] wlan0: WPA2-PSK join on cold boot + ping
- [ ] USB flash drive: automounts, readable on console
- [ ] USB keyboard: types on console (into desktop in S08)
- [ ] BT: hci0 up, scan finds a device
- [ ] Idle RAM delta with all radios on ≤ 60 MB total (S09 budget)
