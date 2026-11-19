# Stage 06 — Power, battery, RTC, IMU

> Phase II · depends on: Stage 03 (Stage 04 for hotkeys) · effort: 2–3 h · status: **not started**

## Goal

The pocket-computer power story: battery % and temperature visible in the
shell, RTC keeping time across full power-off, IMU readable, and the
honest R9 power strategy implemented and measured (no suspend exists on
BCM2837 — we design around it with numbers, not vibes).

## Steps

### 1. Fuel gauge & battery

```sh
doas modprobe bq27xxx_battery               # verify name vs Stage 01 lsmod
cat /sys/class/power_supply/bq27220-0/capacity
cat /sys/class/power_supply/bq27220-0/temp  # deci-°C
cat /sys/class/thermal/thermal_zone0/temp   # SoC
ls /sys/class/power_supply/                 # any charger node? (docs/01 item 8)
```

- [ ] Values sanity-checked against the stock OS readings (Stage 01)

### 2. Status in the prompt

`/etc/profile.d/cpz-status.sh` (all users, ash):

```sh
# battery % + SoC °C, fail-safe when nodes absent
cpz_batt() { cat /sys/class/power_supply/bq27220-0/capacity 2>/dev/null; }
PS1='[$(cpz_batt)% $(cut -c1-2 /sys/class/thermal/thermal_zone0/temp 2>/dev/null).0°C \w]\$ '
```

- [ ] Prompt shows `100% 47°C ~` style status on every login/getty

### 3. RTC

```sh
doas modprobe rtc-rx8130                    # name verified against Stage 01
ls /dev/rtc*
doas hwclock -w                             # system → RTC (after ntpd sync)
doas rc-update add hwclock boot
```

- [ ] The power-cycle test: set clock, `poweroff`, wait 5 min, boot →
      `hwclock -s`-loaded time is right. RTC battery-backed (RX8130CE has
      its own backup supply on the board)

### 4. IMU (BMI270) & magnetometer (BMM150)

```sh
doas modprobe bmi270                        # iio driver per Stage 01 notes
ls /sys/bus/iio/devices/
cat /sys/bus/iio/devices/iio:device*/in_accel_*raw   # tilt the device → values move
# BMM150: driver per Stage 01 (bmm150 / bmc150_magn); raw reads likewise
```

- [ ] accel + gyro values change with movement; magnetometer reads (or is
      honestly marked "raw-only" with an i2c-dev helper if the driver is
      missing in Phase A — record which in docs/01 rows 18/19)

### 5. The R9 power strategy — implement & measure

No suspend-to-RAM exists on this SoC. The strategy is: *fast boot +
blanking + runtime PM + fast clean shutdown*.

- [ ] `consoleblank=60` already in cmdline (Stage 03) — LCD blanks after 1 min
- [ ] Wi-Fi powersave on (Stage 05 hook)
- [ ] USB autosuspend via eudev rule — **except** the USB-ethernet chip
      (smsc95xx keeps the link alive; blacklist it in the rule)
- [ ] CPU governor: `schedutil` (default on rpi kernels; verify
      `/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`)
- [ ] Optional underclock experiment: `arm_freq=700` in config.txt →
      measure drain vs responsiveness; decide, record
- [ ] Clean shutdown hotkey: pick the keycode (from Stage 04's `showkey`
      sweep; a natural choice: a long-press combo the matrix can emit) →
      `triggerhappy` rule → `poweroff`. Prevents SD corruption (R8)
- [ ] **Battery benchmark**: 30 min idle (LCD blanked, radios on) →
      recorded %/hour. This number is the target to beat in S09

## Files produced

`/etc/profile.d/cpz-status.sh` · hwclock service · thd shutdown binding ·
battery benchmark numbers

## Acceptance gate

- [ ] Prompt shows battery + temp on all consoles
- [ ] RTC survives full power-off (5 min)
- [ ] IMU values move; mag status honest (works or documented-raw)
- [ ] Shutdown hotkey works (clean `poweroff`, no SD errors on next boot)
- [ ] 30-min idle drain benchmark recorded (S09's baseline)

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| bq27xxx/rtc module names differ in stock kernel | Stage 01's lsmod is the truth — use its names |
| BMM150 driver absent (Phase A) | i2c-dev + small ash reader script for raw registers; full driver can land with Phase B/C |
| Long-press combos hard on this matrix | single-key shutdown behind SYM layer (thd sees the *resolved* keycode, not the physical press) |
