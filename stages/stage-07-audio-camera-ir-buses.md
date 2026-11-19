# Stage 07 — Audio, camera, IR, Grove & 14-pin bus

> Phase II · depends on: Stage 03 (Stage 05 for network deps) · effort: 4–8 h · status: **not started**
> **This is Gate G2: full hardware support.** The stage where the ES8389
> question (R1) gets answered and, if needed, Phase C gets scheduled.

## Goal

Every remaining peripheral row of `docs/01-hardware-inventory.md` verified:
speakers + mic + jack, HDMI audio, camera (standard model), IR TX/RX, Grove
port, 14-pin expansion bus. At the end, the matrix has zero unverified rows.

## Steps

### 1. Audio (ES8389 — the R1 stage)

```sh
cat /proc/asound/cards            # stock kernel: expect es8389 card + vc4hdmi
doas modprobe snd_soc_es8388      # or whatever Stage 01's lsmod named
doas apk add alsa-utils
doas alsactl init
speaker-test -c2 -twav            # the 1 W speaker
arecord -d5 test.wav              # MEMS mic
# headphone jack: plug in, `alsamixer` → route, `speaker-test` again
```

- [ ] Speaker, mic, jack all pass on Phase A
- [ ] **The Phase B/C decision point:** record the exact driver/module
      names + whether they're mainline. If the ES8389 machine driver is an
      M5-only patch (likely — mainline has es8311/es8328 but not es8389),
      mark **Phase C triggered** in PLAN §5: S10's `linux-cpz` must port
      the patch from M5's GPL source (Stage 01 chased it).
- [ ] `alsactl store` + OpenRC `alsarestore` (or a local.d call) so mixer
      state survives boots

### 2. HDMI audio

- [ ] With HDMI attached: `aplay -l` shows the `vc4hdmi` card; playback
      reaches the monitor. This feeds docs/05's `asound.conf` switching
      (S08), verified here as a card.

### 3. Camera (standard model; skip on Lite)

```sh
doas dmesg | grep -iE 'imx219|unicam'
doas apk add libcamera libcamera-tools v4l-utils   # rpi support — verify pkgs
libcamera-hello --list              # camera enumerated?
libcamera-hello -t 5000             # 5 s preview to LCD/HDMI
libcamera-jack? no — libcamera-still -o /tmp/t.jpg
```

- [ ] Stills capture works; a photo lands in `/tmp`
- [ ] **Scoped deliberately:** camera is an on-demand CLI app, *never* a
      boot service (R6 — libcamera's daemon stays off the 512 MB budget)
- [ ] If the rpi camera stack fights Alpine's libcamera version: record
      it, try `v4l2` direct (`v4l2-ctl --stream-mmap`), and defer —
      camera is the one peripheral allowed to land post-G2 without shame

### 4. IR (TX/RX)

Per Stage 01's DT notes:

```sh
doas modprobe gpio_ir_recv         # and/or gpio-ir-tx / pwm-ir-tx per topology
ir-ctl -t nec -k 0x00ff             # TX test — point at a device/phone camera
mode2 -d /dev/lirc0                 # RX test with any remote
```

- [ ] TX observed (phone camera sees the LED blink, or a target device
      reacts); RX decodes a stock remote

### 5. Grove HY2.0-4P port

```sh
doas apk add i2c-tools
doas i2cdetect -y <bus from Stage 01 notes>   # TCA8418, RTC, gauge, IMU visible
```

- [ ] The port's switch mechanism (I2C vs UART) documented from the DT +
      stock behavior; whichever mode is default, verified reachable from
      userspace (`/dev/i2c-*` or `/dev/ttyAMA*`)

### 6. 2.54 mm 14-pin expansion bus

- [ ] Pinout table written into docs/01 (from M5Stack's published docs +
      DT): SPI, UART (the serial console we've been using!), I2C, USB, 5V
- [ ] Each exposed interface reachable: `spidev` node, i2c bus, gpio via
      `/sys/class/gpio` or libgpiod — quick loopback/blink test per bus

## Files produced

alsa state + services · camera tool notes · IR module list · bus pinout
table in docs/01 · **the Phase B/C driver checklist** (R1 outcome)

## Acceptance gate (G2)

- [ ] Speaker/mic/jack pass; HDMI audio passes
- [ ] Camera captures (std model) or is documented-deferred with cause
- [ ] IR TX seen, RX decodes
- [ ] Grove + 14-pin buses reachable from userspace
- [ ] **Every row of docs/01 marked supported-or-explained** — zero TBD
- [ ] Phase B/C decision recorded in PLAN §5 with the driver evidence

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| ES8389 is M5-patched (expected) | Phase A keeps audio working now; Phase C (`linux-cpz`, S10) ports the patch; GPL source request from S01 was the dependency |
| libcamera too heavy / incompatible | v4l2 direct access; camera = documented on-demand app (R6) |
| IR topology surprising (e.g. PWM-driven) | follow the DT; `pwm-ir-tx` path exists for exactly that |
| Grove switch needs a GPIO write | small `cpz-grove` helper script; document in rootfs-overlay |
