# 06 — Testing runbook & regression checklist

Every claim in this project ends as a line here with evidence. Run the smoke
set after each stage; run the full set at every gate (G1–G4) and before
calling any release done.

## 1. Per-boot smoke (2 minutes, after any change)

```sh
# console alive on LCD, right font & keymap
cat /sys/class/graphics/fb0/virtual_size          # 320,170
ps | grep -c getty                               # ≥ 1
# battery & temp readable
cat /sys/class/power_supply/bq27220-0/capacity
cat /sys/class/thermal/thermal_zone0/temp
# radios present
ip link                                           # eth0 + wlan0 (when drivers up)
# no forbidden graphical processes
pgrep -c sway || echo "sway absent: OK"
# RAM budget
free -m
```

## 2. Per-stage gates (acceptance summaries live in each stage file)

| Gate | After | Proof required |
|---|---|---|
| G1 | S03 | readable console on internal LCD at cold boot; `dmesg` clean panel probe; boot time logged |
| G2 | S07 | full matrix of docs/01: keyboard (all SYM combos), USB, eth, wifi, BT, battery, RTC, IMU, audio, camera, IR, buses |
| G3 | S08 | docs/05 §6 checklist, incl. 10× start/stop leak loop |
| G4 | S10 | scripted build ×2 from clean checkout → both images pass this full runbook |

## 3. Full hardware regression (G2+)

- [ ] Keyboard: every printed key + all blue SYM symbols correct on console
      (`/` = SYM+N per legends; full sweep from the keymap)
- [ ] USB: flash drive automount r/w; keyboard + mouse enumerate
- [ ] Ethernet: DHCP lease + ping, cold boot, cable-pull/reinsert recovery
- [ ] Wi-Fi: WPA2 join at boot + ping; `iw dev wlan0 link` sane; powersave on
- [ ] Bluetooth: `hciconfig hci0 up` + scan finds devices
- [ ] Battery: % + temperature correct (compare against stock OS reading)
- [ ] RTC: set clock, full power-off 5 min, boot → time preserved
- [ ] IMU: iio accel/mag values change when the device is moved
- [ ] Audio: speaker test tone, mic record, headphone jack, HDMI audio in
      desktop session
- [ ] Camera (standard model): `libcamera-hello` preview, still capture
- [ ] IR: TX observed by a receiver (phone camera trick for the LED if
      nothing else); RX from a remote
- [ ] Grove + 14-pin bus: i2cdetect sees TCA8418 (+ RTC/fuel gauge/IMU
      addresses); SPI/UART/GPIO loopback as available
- [ ] Thermal: SoC temp under 5 min CPU load (stress via `yes >/dev/null`
      ×4) stays in safe range, no throttling surprises

## 4. "On demand" regression (G3)

- [ ] Cold boot → `pgrep sway` empty, `free -m` idle ≤ 60 MB (radios on)
- [ ] HDMI hotplug in `ask` mode → LCD notice, no session until commanded
- [ ] `auto` mode → session by itself; stop returns RAM within 10 MB
- [ ] LCD console readable *during* the entire HDMI session
- [ ] Both GPU profiles boot-switchable via `cpz-desktop-profile` + reboot

## 5. Budget measurements (how to measure, honestly)

```sh
# boot time: timestamp the first user-visible prompt
# (read the OpenRC boot log timestamps; dmesg timestamps cover kernel side)
dmesg | tail -1        # kernel time base
# plus a stopwatch for firmware+init → prompt on the LCD
# idle RAM: after 2 min of sitting still, radios on
free -m
# service-by-service cost when hunting:
for p in $(ps -eo pid --no-headers); do grep -H VmRSS /proc/$p/status 2>/dev/null; done \
  | sort -t: -k2 -n | tail -20
```

Numbers land in PLAN §6 tables as *measured* (replacing targets) during S09.

## 6. Build reproducibility (G4)

- [ ] `build/` scripts run clean on a fresh checkout: fetch → rootfs →
      kernel → image
- [ ] Two consecutive builds produce images whose `sha256` differ only by
      timestamps (or are bit-identical if we pin that far — stretch)
- [ ] Both images pass §1 + §3 + §4 on the device
- [ ] Release artifact: `images/cpz-alpine-<ver>.img.gz` + `.sha256` +
      CHANGELOG entry
