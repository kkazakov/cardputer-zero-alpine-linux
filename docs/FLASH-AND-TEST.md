# FLASH AND TEST — CPZ-Alpine 0.21.2

Built offline from M5's own stock image (Phase-A kernel graft). Core
hardware support is field-verified through v0.19.0; v0.20.0 added the
Files browser and Camera as default launcher applications, v0.20.1 fixes
MIPI-CSI camera startup and opens Files in `/home/cpz`, v0.21.0 makes
the `CPZDATA` persistence partition cover the rest of the card on every
flash route, v0.21.1 installs `shadow` so `passwd` works as `cpz`, and
v0.21.2 preserves root/cpz password changes across a reflash. Items
marked [TEST] below still deserve one device pass.

## What you're flashing

- `images/cpz-alpine-0.21.2.img.gz` (+ `.sha256`) — 1.8 GiB raw image:
  FAT32 boot (256 MiB) + ext4 root (1.5 GiB), MBR disk id `0x10c0ffee`
- Base: Alpine Linux 3.24 aarch64, musl + BusyBox + OpenRC, **no systemd**
- Kernel: M5 stock `6.18.33+rpt-rpi-v8` (bit-exact from the factory image,
  incl. the M5 out-of-tree modules: panel, keypad, audio, gauge, IMU)
- Boot: stock VideoCore firmware + stock DTB set + stock
  `cardputerzero-overlay` — **u-boot removed** (direct kernel8.img boot,
  the direction of M5's current pi-gen branch)

## Flashing

The public download is the release ZIP:
<https://github.com/kkazakov/cardputer-zero-alpine-linux/releases>.
It contains the image, checksum, README and Linux/Windows/macOS flashers.

```sh
sha256sum -c cpz-alpine-0.21.2.img.gz.sha256     # verify download
# /dev/sdX = the LAB microSD card (NOT the stock card, NOT a disk!)
# built-in laptop reader: /dev/mmcblk0 (v0.21.5+ handles mmcblk/nvme names)
lsblk                                          # triple-check sizes
sudo ./flash-cpz.sh /dev/sdX                   # preserves /cfg on reflashes
# or: sudo ./flash-cpz.sh /dev/mmcblk0
```

`flash-cpz.sh` verifies the checksum, unmounts the card, writes the image,
creates the CPZDATA partition at the fixed 4 GiB offset up to the end of
the card, formats it only when it is missing/corrupt, and grows its ext4
filesystem to the partition. **It is the only route that keeps `/cfg`
across a reflash.**

`dd`, Raspberry Pi Imager and balenaEtcher work too — they write only the
boot and root partitions, and the device provisions CPZDATA itself on the
first boot. That costs **one extra reboot** on a brand-new card (the
kernel cannot see a new partition table while the root partition is
mounted, so the card must reboot once before the filesystem can be
created). Nothing else is different:

```sh
gunzip -c cpz-alpine-0.21.2.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Or use Raspberry Pi Imager / balenaEtcher with the `.img.gz` directly.

The image itself is fixed-size (1.8 GiB); everything after it belongs to
CPZDATA. The size is decided by the card you flash — a card whose
filesystem is smaller than its partition (e.g. flashed from a smaller card)
is grown on the next boot. There is no shrinking: to move to a bigger card,
flash the bigger card.

## What should happen on first boot

1. No splash. The LCD stays dark for a few seconds (kernel + OpenRC
   starting — this build loads the panel driver from the rootfs, not an
   initramfs — that's the accepted R2 fallback: "UI appears seconds
   later, still usable").
2. Then the **APPLaunch launcher UI** takes over the internal LCD
   (v0.18: the launcher runs as user **cpz** with passwordless sudo and
   the video/input/audio/i2c/seat groups). You get the Alpine wallpaper,
   the status bar (clock, battery, Wi-Fi state) and the app carousel.
3. **HDMI stays dark** — no splash, no kernel console, no getty on the
   VTs (v0.18). HDMI only comes up when the desktop is started, from the
   **HDMI** app or `cpz-desktop start`. The local rescue console is
   serial0 (115200); SSH is the normal remote path.
4. Wi-Fi joins automatically when an NM profile is baked (built from
   `build/wifi-secret`) — otherwise join from Settings → Wi-Fi.
5. **On a card written with `dd`/Imager/Etcher**, the first boot ends with
   an automatic reboot: `cpz-grow.start` appends the CPZDATA entry to the
   end of the card, and the new geometry is only visible after the reboot,
   where the filesystem is created. You see the launcher once, the device
   reboots itself, and the second boot is the normal one. From there on it
   never reboots by itself again. `flash-cpz.sh` cards skip all of this —
   their `/cfg` is already there. If the device reboots over and over,
   `/cfg` is not reachable and `cpz-grow.start` has nothing to do; it gives
   up after one attempt and stops rebooting — check the serial console for
   `cpz-grow:` lines.

## Test checklist (in order)

- [ ] **T1 — launcher on LCD**: the APPLaunch carousel appears on the
      internal screen within ~15 s of power-on, over the Alpine
      wallpaper. Cards cycle ←/→ (or Z/X); Enter opens, ESC backs out /
      long-press returns home. The status bar shows the clock and a
      battery percentage. If the panel is dark: check
      `rc-service applaunch status` over SSH — `/var/log/applaunch.log`
      carries the launcher's stderr. A `crashed` status with an **empty**
      log means the service never exec'd: start-stop-daemon drops to
      `cpz` before opening the log file, so `/var/log/applaunch.log` must
      be cpz-writable (`ls -la /var/log/applaunch.log` → `cpz cpz`, 0664;
      the init script enforces this in `start_pre` since v0.18.1).
- [ ] **T1b — dark HDMI**: with a monitor plugged, the screen shows
      **no console text** during boot or idle: `/proc/cmdline` has only
      `console=serial0` and `/etc/inittab` only a ttyS0 getty.
- [ ] **T1c — HDMI app** [TEST]: open the **HDMI** card → the switch
      reflects the live session; ENTER flips it On → sway + waybar
      appear on the monitor, and the LCD shows **HDMI LOCKED** after a
      1 s grace period (the launcher stops reading the internal keypad so
      keys do not double-type). Off → the session stops and the LCD
      unlocks. Reboot with it On and the session starts by itself
      (`/var/lib/applaunch/hdmi-desktop` holds "1"); turn it Off before
      the next reboot to keep HDMI dark.
- [ ] **T2 — keyboard (through the launcher)** [TEST]: ←/→ (Z/X) cycle the
      carousel; Enter opens the focused card; ESC backs out, long-press
      ESC returns home from anywhere. The SYM layer: open the **CLI**
      terminal card and type — `/` should be **SYM+N** (per printed
      legends), `!` SYM+1 etc.; SHIFT/FN modifiers behave per keycap.
      The launcher reads raw evdev and maps the SYM layer from
      `/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map` — the same
      field measurements as the console map.
- [ ] **T2b — Calculator** [TEST]: open the Calculator card; digits,
      operators, `=` compute; ESC (long-press) returns to the carousel.
- [ ] **T2c — Settings** [TEST]: Settings → Screen → Brightness steps the
      backlight; Speaker → volume keys work (ES8389 via ALSA); Wi-Fi →
      Networks lists APs and joins with a password (NetworkManager
      writes the profile; a reboot rejoins automatically); Date & Time →
      Set Manually moves the status-bar clock and *Write RTC?* persists
      it across a reboot. The System menu shows Storage / Licenses /
      Reboot but NO Software-updater page, and no Developer/ADB section —
      those are RPi-OS-only and hidden on Alpine.
- [ ] **T2d — Files and Camera (v0.20.1)** [TEST]: the carousel shows
      **Files** and **Camera** between IP Panel and Calculator, both
      enabled by default (Settings → Launcher lists them as preinstalled).
      Files opens in `/home/cpz`; create/copy/rename a file there, then
      check `ls -la /home/cpz`. Camera opens the MIPI-CSI sensor through
      libcamera, shows a live preview, takes a still, and the gallery
      shows it; the file lands in `/home/cpz/Pictures/DCIM/Camera`. Both
      apps must return to the carousel with ESC. A missing app means the
      Files/Camera binary did not ship — see `/var/log/applaunch.log` for
      a rejected `.desktop`.
- [ ] **T2e — Files/Camera persistence (v0.20.1)** [TEST]: put a marker
      file in `/home/cpz`, take one photo, run `cpz-save`, then reflash
      the same card with `build/flash-cpz.sh` (it preserves `CPZDATA`).
      After boot, the marker and the photo are back. For a quick archive
      check without reflashing:
      ```sh
      tar -tzf /cfg/save.tar.gz | grep -E 'home/cpz/(notes.txt|Pictures/DCIM/Camera)'
      ```
      The whole `/home/cpz` tree is pass A (archive wins) in
      `cpz-restore.start`, so Files content and camera media ride the
      same snapshot as Wi-Fi, hostname and launcher settings.
- [ ] **T2f — `/cfg` self-provisioning (v0.21.0, needs hardware)** [TEST]:
      write a brand-new card with `dd` (or Etcher) — **not** `flash-cpz.sh`.
      Boot it: the device should reboot itself once, then on the second boot
      ```sh
      sfdisk -l /dev/mmcblk0          # p3 CPZDATA ends at the end of the card
      df -h /cfg                      # covers the card, not 1.8 GiB
      mount | grep /cfg               # ext4, rw
      grep cpz-grow /var/log/messages # created CPZDATA / CPZDATA formatted
      ```
      Reboot twice more: it must stay silent and never reboot again. A
      reflash with `flash-cpz.sh` afterwards must keep `/cfg/save.tar.gz`.
- [ ] **T2g — password persistence (v0.21.2)** [TEST]: as `cpz`, run
      `passwd` and change the password. Then `sudo -n cpz-save` and check:
      ```sh
      stat -c '%a %U:%G' /cfg/shadow-users    # 600 root:root
      cut -d: -f1 /cfg/shadow-users           # exactly root, cpz
      ```
      Reflash the same card with `build/flash-cpz.sh` (preserves `/cfg`).
      After boot the new cpz password must work; a password change made
      without a following `cpz-save` is lost. Accounts other than root/cpz
      always come from the new image — `/etc/shadow` is never restored
      wholesale. **Upgrading from ≤v0.21.1:** those images never wrote
      `shadow-users`, so the first v0.21.2 boot still has the build-time
      `alpine` password even if you had changed it before the reflash;
      set it again, then save.
- [ ] **T2h — Tailscale on/off (v0.21.3)** [TEST]: the card only exists
      when the optional package is installed **and** logged in. With
      Tailscale absent (fresh image) it must **not** appear on the home
      carousel or in Settings → Launcher. Then:
      ```sh
      sudo apk add tailscale tailscale-openrc
      sudo tailscale up                 # authenticate
      ```
      Within ~20 s the **Tailscale** card appears without restarting
      `applaunch` (the home screen re-polls the availability predicate).
      Open it: the switch shows the live daemon state. ENTER toggles:
      ```sh
      pgrep -x tailscaled                    # present when On, gone when Off
      sudo cat /var/lib/applaunch/tailscale  # 1 / 0
      ls /etc/runlevels/default/tailscale    # link present when On, gone when Off
      sudo rc-service tailscale status
      ```
      Reboot with it On: it comes back by itself. Reboot with it Off: the
      daemon must not start at all (the runlevel link is removed, so
      OpenRC never starts it before the boot hook runs).
      **Warning:** on a device reachable only over its tailnet address,
      switching Off cuts your SSH session. Keep a serial console or
      schedule a re-enable (for example
      `nohup sudo -n sh -c 'sleep 120; /usr/local/bin/cpz-tailscale apply on' >/dev/null 2>&1 &`)
      before testing Off remotely.
      Manual control works too: `sudo cpz-tailscale on|off` writes the
      preference and applies it; `sudo cpz-tailscale boot` re-applies it.
      After a reflash with `flash-cpz.sh`, `sudo cpz-save` must have
      archived `/var/lib/tailscale`:
      ```sh
      sudo tar -tzf /cfg/save.tar.gz | grep var/lib/tailscale/tailscaled.state
      ```
      The node comes back logged in once the apk reinstall finishes (no
      second `sudo tailscale up`).
- [ ] **T2i — OFF survives a reboot (v0.21.4)** [TEST]: with the tunnel
      ON, write an archive that still says ON, then switch OFF and reboot
      (or run the boot path directly):
      ```sh
      printf '0\n' > /var/lib/applaunch/tailscale
      sudo rc-update del tailscale default
      sudo /etc/local.d/cpz-restore.start      # archive still holds "1"
      sudo cat /var/lib/applaunch/tailscale    # must still be 0
      sudo /etc/local.d/cpz-tailscale-boot.start
      pidof tailscaled                         # must print nothing
      ls /etc/runlevels/default/tailscale      # must not exist
      ```
      The v0.21.3 bug was the first step: `cpz-restore` copied the stale
      `1` over the live `0`. After a real reboot the same checks apply
      (`cat` is `0`, no `tailscaled`, no runlevel link). A **fresh flash**
      must still restore the saved value, because the image ships an empty
      `/var/lib/applaunch` — that case is the only one where the archive
      is copied.
- [ ] **T2j — setup then reflash keeps everything (v0.21.6)** [TEST]:
      this is the reported regression. On a freshly flashed card:
      1. join Wi-Fi, `sudo apk add tailscale tailscale-openrc`,
         `sudo tailscale up`, and set a password with `passwd`;
      2. confirm a save happened **without** a manual command:
         ```sh
         sudo ls -l /cfg/save.tar.gz        # mtime within the last 5 min
         logread | grep -E 'cpz-save|dispatcher' | tail
         sudo tar -tzf /cfg/save.tar.gz | grep -E \
           'shadow-users$|root/.ssh|NetworkManager/system-connections|var/lib/tailscale/tailscaled.state'
         ```
         The NM connect hook should have saved within seconds of joining;
         the 5-minute cron is the fallback;
      3. `sudo poweroff` (a clean shutdown — the `cpz-save.stop` hook
         runs), move the card to the reader and reflash with
         `flash-cpz.sh`;
      4. boot: the password works, `/root/.ssh/authorized_keys` is back,
         Wi-Fi rejoins by itself, `sudo cpz-tailscale state` is `on`, and
         `/var/lib/applaunch/tailscale` kept its value.
      A **dirty** `/cfg` (unclean shutdown) must be repaired, not wiped:
      the flasher prints `CPZDATA needs a journal replay/repair —
      repairing, NOT formatting`. Pulling the card while running is still
      a loss of anything newer than the last 5-minute snapshot.
- [ ] **T3 — serial rescue**: the normal image has **no USB-C serial
      gadget** (dwc2 is host-only for Ethernet/USB-A). Use the 14-pin
      expansion UART at 115200, or SSH. If the LCD is dark and you have
      no UART adapter, the legacy `build/offline-fix/fix-card.sh` can
      temporarily patch the card to `dwc2,dr_mode=peripheral` + `g_serial`
      and expose `/dev/ttyACM0` at 115200 — treat that as an emergency
      recovery path, not a normal feature.
- [ ] **T4 — USB host**: plug a USB flash drive into the USB-A port →
      `dmesg | tail` shows usb-storage; plug a USB keyboard → types.
- [ ] **T5 — Ethernet**: cable in → `ip a` shows eth0 with a DHCP lease;
      `ping -I eth0 -c3 1.1.1.1`. Since v0.12.2 the SR9900A is driven
      by a patched r8152 (mainline ID 0x0fe6:0x9900), dwc2 in host
      mode — field-verified on hardware. (The USB-C serial gadget was
      retired for host mode; Wi-Fi/Ethernet SSH is the remote path.)
- [ ] **T6 — SSH**: from your LAN: `ssh root@<ip>` (password `alpine`).
      Key-only lockdown comes later (S09) — don't expose this image.
- [ ] **T6b — passwd (v0.21.2)**: as `cpz` (CLI app), `passwd` asks for
      the current password and changes it — **not** `passwd: must be suid
      to work properly`. `stat -c '%a %U:%G' /usr/bin/passwd` must print
      `4755 root:root`. Root reset path: `sudo -n passwd cpz` (cpz has
      NOPASSWD sudo). After changing a password, run `cpz-save` (or wait
      for the hourly job); v0.21.2 stores only the `root`/`cpz` lines in
      `/cfg/shadow-users` for the next reflash.
- [ ] **T7 — Wi-Fi chips present**: `ip a` shows wlan0 (unconfigured —
      see below to join a network). `iw dev wlan0 scan | grep SSID` should
      list networks.
- [ ] **T7b — Wi-Fi Settings (v0.19.1)**: Settings → Wi-Fi → Enable
      really toggles the radio (no flash-and-revert), and Networks joins a
      WPA2 AP. The launcher runs `nmcli` through the passwordless
      `/usr/local/bin/cpz-nmcli` sudo wrapper because Alpine's
      NetworkManager has no polkit; direct `nmcli` as cpz fails with
      "Not authorized to perform this operation".
- [ ] **T8 — battery**: `cat /sys/class/power_supply/bq27220-0/capacity`
      now reports a real percentage (v0.5 rebuilt the gauge driver with
      true BQ27220 support). `power_now` / `voltage_now` should read sane
      values, and `dmesg | grep bq27` must show **no** `-121` errors.
- [ ] **T8b — keyboard LEDs**: the three SHIFT/FN/SYM LEDs must be OFF at
      idle (they used to cycle endlessly). Press SHIFT → its LED lights
      while held; double-press behavior (locked mode) is the driver FSM's.
- [ ] **T9 — audio**: `speaker-test -c2 -twav` (ES8389 speaker path) and
      `alsamixer` (F6 to pick the es8389 card).
- [ ] **T10 — HDMI desktop (on demand)** [TEST]: plug into a monitor.
      Nothing starts by itself (`/etc/cpz/hdmi-mode=ask`; start it from
      the HDMI card). Run `cpz-desktop start`: sway + waybar + foot come
      up in ~5 s, ~90 MiB resident. The internal LCD is not a Sway output
      (fbtft is not KMS); it shows **HDMI LOCKED** while the session runs,
      as described below.
      **Internal keypad in sway (v0.19.0):** Alt is scoped to Super for
      the internal device only, so the stock bindings work:
      Alt+Enter terminal, Alt+d launcher, Alt+Shift+E stop.
      The cpz XKB layout (`/usr/share/X11/xkb/symbols/cpz`) is used with
      the `cpz:sym` XKB option. XKB's `inet(evdev)` section runs after
      the layout and redefines the internal SYM codes as media keys;
      options run last, so `cpz:sym` supplies the real symbols. The
      option is set for all keyboards because the Wayland seat shares one
      keymap; cpz includes `us(basic)`, so external keyboards still type
      US. Alt-as-Super is scoped to the internal device. SYM+1..0 and
      SYM+Q..P then type the printed characters in sway/foot.
      Verified on hardware: SYM+1=!, SYM+2=@, SYM+Q=~, SYM+;=;,
      Fn+Z=Left. XKB options are comma-separated (`cpz:sym,altwin:...`);
      a space-separated list is one unknown option and is dropped.
      Arrows are Fn+Z/X/C/F; use Alt+Fn+Z/X/C/F to focus and
      Alt+Shift+Fn+Z/X/C/F to move a window.
      **Lock:** after 1 s the LCD shows **HDMI LOCKED** and the launcher
      stops consuming keypad events. Hold **ESC for 2 s** to stop the
      desktop and unlock the LCD (a single ESC does nothing). Alt+Shift+E
      on the internal keypad, or Super+Shift+E on an external keyboard,
      also stops the desktop. Any sway exit unlocks the LCD and writes
      the HDMI preference off.
      **External keyboard:** unchanged — real Super/Alt and the US layout;
      it goes straight to sway, not the launcher.
- [ ] **T11 — camera sensor (field-verified method)**: with v4l-utils on the
      device (kept across reflashes by the persistence pkglist):
      ```sh
      v4l2-ctl -d /dev/video0 --set-fmt-video=width=3280,height=2464,pixelformat=pRAA
      v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=1 --stream-to=/tmp/frame.raw
      ```
      Pull `/tmp/frame.raw` off the device and convert host-side:
      `python3 build/tools/debayer-srggb10.py frame.raw camera-test.jpg`.
      Healthy output: 10-bit stats using the full 0–1023 range.
- [ ] **T12 — Bluetooth**: `rc-service bluetooth status` shows the
      daemon running with `hci0` up (BCM4343A2 firmware loads at
      boot). Pairing: make a device discoverable, then
      `bluetoothctl scan on` + `bluetoothctl pair <mac>`.

## Wi-Fi on the device (post-flash)

### On-demand graphical apps (NOT baked — apk add when wanted)

Persistence carries anything you install across reflashes automatically
(hourly snapshot; run `cpz-save` right after installing to be safe).
Recommended light picks for the HDMI session:

```sh
apk add imv        # Wayland-native image viewer, a few MB
apk add lf         # terminal file manager, zero GUI cost
apk add epiphany   # the browser — Wayland-native, but WebKit:
                   # ~100-200 MiB with a page open on this 512 MB board,
                   # fine for light pages
```
All appear in the Super+d launcher. The default session terminal is
**foot** (Super+Enter); Tilix is installed but never auto-starts —
open it from the launcher when you want pane splits
(Ctrl+Shift+O/E).

```sh
vi /etc/wpa_supplicant/wpa_supplicant.conf    # add your network block
vi /etc/network/interfaces                   # uncomment wlan0 stanza
rc-service networking restart
```

## If it doesn't boot

Ranked escape hatches:

1. **Serial console** (T3) — the kernel logs everything to `serial0`
   (mini-UART, 115200 8N1) even when the display stack fails.
2. **Stock card**: untouched — the factory OS restores the device in
   one flash.
3. Boot with HDMI: this build gives HDMI a KMS console via vc4
   (`console=tty1` only claims the LCD) — a monitor may show *something*
   even mid-failure. [TEST]

Capture for me: `dmesg` output (via serial or SSH), a photo of whatever
the LCD shows (including "nothing"), and whether the backlight glows.

## Known deviations from PLAN.md (v0.1, all documented in build/)

- No initramfs yet (R2 fallback; mkinitfs config staged for S03)
- No HDMI desktop (S08), no triggerhappy (not packaged in Alpine 3.24,
  S04 risk — vendoring or an evdev-script stopgap comes later)
- Wi-Fi/BT: firmware + services in place, BT attach script not yet (S05)
- Boot is verbose on purpose (no `quiet`) — first-flash observability
  beats boot-time budgets until S09.
