# Stage 01 — Hardware discovery & BSP harvest

> Phase I · depends on: Stage 00 · effort: 2–3 h · status: **not started**

## Goal

One careful pass on the **unmodified stock OS** to (a) resolve every `TBD`
in `docs/01-hardware-inventory.md` with real evidence, and (b) export the
`harvest/` bundle: DTB, overlays, panel firmware, Wi-Fi/BT firmware, keymap,
Phase-A kernel + modules, kernel config, diagnostics. After this stage, the
stock card goes back in its box — we never need it again.

## Steps

### 1. Boot stock and get in

- [ ] Complete the stock onboarding: Wi-Fi + SSH (the demo app walks you
      through it). Note: this is the *only* time we interact with the M5
      demo layer — treat it as a BIOS, not as software to keep.
- [ ] SSH in as the stock user; `sudo -s` for root.

### 2. Empirical identification (fills docs/01 TBD items)

```sh
cat /proc/device-tree/model            # the exact DT identity — write it in docs/01
grep -E 'device_tree|dtoverlay' /boot/firmware/config.txt   # how the DTB is selected
lsusb                                  # ethernet chip + hub identity (row 11)
lsmod | grep -iE 'es83|es84|snd_soc'   # ES8389 driver reality (row 16, risk R1)
lsmod | grep -iE 'bmm|bmi'             # IMU/mag drivers (rows 18/19)
cat /proc/bus/input/devices            # keyboard + power button inputs (rows 8/27)
```

- [ ] USB-C data port: plug the keyboard into each USB-C; watch `dmesg` —
      record which one is OTG data, which is power-only (docs/01 row 10)
- [ ] Power button: short vs long press behavior (row 27)
- [ ] `/sys/class/power_supply/` — note every node (fuel gauge + any
      charger IC, docs/01 row 22 + open item 8)
- [ ] Camera (standard model): stills capture works on stock → confirms
      the whole unicam/imx219 path is usable (row 15)

### 3. Run the harvest script

Execute the full block from
[docs/02-stock-os-and-harvest.md §3](../docs/02-stock-os-and-harvest.md)
(root on stock, over SSH), then move the tarball to the build host:

```sh
# on your host:
mkdir -p /home/wasp/projects/cardputer-zero-alpine/harvest
tar -C /home/wasp/projects/cardputer-zero-alpine/harvest \
    -xzf /path/to/cpz-harvest-*.tar.gz --strip-components=1
sha256sum -c cpz-harvest-*.sha256
```

- [ ] Verify the bundle contains: `boot/kernel8.img`, `modules/`,
      `firmware/brcm/`, the panel `st7789` blob, the keymap `.map`,
      `dtb/active.dts`, and all `logs/` dumps
- [ ] **Decompile the DT and actually read it** — it's the board's only
      datasheet: i2c devices (TCA8418, BQ27220, RTC, IMU addresses), SPI
      panel node (which firmware file it requests!), audio machine nodes,
      IR topology, dwc2 mode, Grove/14-pin muxing. Take notes into docs/01.

### 4. Chase the GPL kernel source (Phase C dependency, do it now)

- [ ] Search M5Stack's GitHub org for the CardputerZero kernel tree
      (patches to the Raspberry Pi kernel for panel/audio/machine drivers).
- [ ] If absent: request source per GPL (they must offer it) via support
      channels; note the request date in docs/01.
- [ ] This is not urgent for Phases A/B, but R1 (ES8389 audio) makes it the
      most likely Phase C input — ask early, wait passively.

### 5. Close the loop on docs

- [ ] Every `TBD` in `docs/01-hardware-inventory.md` → filled with the
      observed chip/driver/path
- [ ] Status column updated to `identified` for those rows
- [ ] The exact active-DTB filename + `device_tree=`/`dtoverlay=` selection
      mechanism recorded in docs/03 §4 (it feeds Stage 03's config.txt)

## Files produced

`harvest/` (complete, gitignored) · updated `docs/01-hardware-inventory.md`

## Acceptance gate

- [ ] All docs/01 rows state `identified` or `planned` — zero `TBD`
- [ ] Harvest bundle checksummed and stored on two media
- [ ] DTB decompiled and annotated (i2c map noted: keypad, gauge, RTC, IMU)
- [ ] GPL source request sent (or source found)

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| Stock SSH unavailable (onboarding stuck) | use HDMI + USB keyboard, or serial console from the 14-pin bus |
| `dtc` missing on stock | copy DTB out, decompile on the host |
| M5 kernel source nowhere public | stay on Phase A indefinitely (all hardware still works); Phase C blocked only, not the project |
