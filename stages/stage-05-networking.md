# Stage 05 — Networking: USB host + wired + wireless

> Phase II · depends on: Stage 03 · effort: 2–4 h · status: **not started**

## Goal

All three network planes from [docs/04](../docs/04-networking.md) pass on
the CPZ: USB host ports enumerate and automount, Ethernet DHCPs on cold
boot, Wi-Fi joins WPA2 on cold boot, Bluetooth scans. This is the stage the
"USB + wired network + wireless network" requirement gets its evidence.

## Steps

### 1. USB host

```sh
doas dmesg | grep -iE 'dwc2|usb'          # host mode active? hub enumerated?
lsusb                                     # hub + ethernet chip visible
# plug the USB flash drive:
doas tail -f /var/log/messages            # usb-storage attaches, partition seen
```

- [ ] Flash drive automounts under `/media/...` (eudev rule from S02's
      `setup-devd udev`; if no mount helper exists, write the small rule →
      `rootfs-overlay/etc/udev/rules.d/`)
- [ ] USB keyboard types (into console now; into the desktop in S08)

### 2. Wired Ethernet

```sh
doas modprobe smsc95xx                    # or r8152/asix — per Stage 01 ID
ip link set eth0 up
udhcpc -i eth0                            # busybox DHCP
ping -c3 1.1.1.1
```

Then make it declarative — `/etc/network/interfaces` exactly as
[docs/04 §2](../docs/04-networking.md), `rc-update add networking boot`
(already from S02).

- [ ] Cold boot with cable in → lease + ping, no manual steps

### 3. Wi-Fi

```sh
# firmware is already in /lib/firmware/brcm (Stage 03 graft)
doas modprobe brcmfmac
iw dev                                    # wlan0 up?
iw dev wlan0 scan | head                   # APs visible?
```

- [ ] `/etc/wpa_supplicant/wpa_supplicant.conf` per docs/04 §3 (your SSID,
      `country=BG` → your country)
- [ ] `rc-update add wpa_supplicant boot` (before `networking` — the
      dependency note in docs/04 §6)
- [ ] Reboot test: joins + DHCP + ping on cold boot
- [ ] Powersave: `iw dev wlan0 set power_save on` in a local.d hook; note
      the drain difference for S06's battery benchmark

### 4. Bluetooth

```sh
doas apk add bluez
# attach per stock mechanism (Stage 01's units.txt/hci.txt tell which):
doas hciattach -n /dev/ttyAMA0 bcm43xx 921600 noflow - <path-to-hcd>   # pattern
# or btattach equivalent; the harvested .hcd name goes here
hciconfig hci0 up
bluetoothctl scan on                      # 15 s — devices appear?
```

- [ ] Wrap the working attach in `/etc/init.d/cpz-bt` (OpenRC), enable it
- [ ] Record RAM cost (target ≤ 8 MB; budget in docs/06 §1 idle ≤ 60 MB)

### 5. Optional / deferred (do not block the gate)

- USB-C **gadget mode** (`g_ether` for laptop USB networking): deferred to
  S09 polish — see docs/04 §5; requires DT mode juggling, never break
  host mode for it
- **avahi** (`cpz.local`): decide after S09 RAM measurements

## Files produced

`/etc/network/interfaces` · wpa config · udev automount rule ·
`/etc/init.d/cpz-bt` · RAM/boot cost notes

## Acceptance gate

- [ ] USB flash: automount, read+write; USB keyboard: types
- [ ] eth0: DHCP + ping on cold boot; unplug/replug recovers (udhcpc retry)
- [ ] wlan0: WPA2 join + ping on cold boot; powersave on
- [ ] hci0: up + scan finds devices
- [ ] Idle RAM with all radios on recorded (feeds the ≤ 60 MB budget)

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| brcmfmac refuses nvram (name/format mismatch) | file must match the DT's exact compatible string — copy *verbatim* from stock (harvest), never rename |
| Ethernet driver missing in Phase-A stock kernel modules? | impossible by construction (stock kernel drives stock eth); Phase B is where this could bite — checklist in Stage 09 |
| wpa race at boot (connect-before-ifup) | `rc.conf` dependency order; worst case `wpa_actiond`-style wait loop in a local.d hook |
| BT attach script needs Pi-specific UART flags | mirror the stock `btuart`/unit behavior recorded in Stage 01 |
