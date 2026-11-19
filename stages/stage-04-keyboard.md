# Stage 04 — Keyboard & console input

> Phase II · depends on: Stage 03 (G1) · effort: 1–2 h · status: **not started**

## Goal

All 46 keys work on the console, including the blue **SYM layer** (the
stock OS only loads this map inside its demo app — we do it properly, at
the system level). Plus `triggerhappy` wired up so physical keys can act
(power-off, later desktop toggles).

## Steps

### 1. Confirm the keypad driver probed

```sh
cat /proc/bus/input/devices      # TCA8418 event device present?
doas dmesg | grep -i tca8418
ls /dev/input/event*             # note the event node for thd later
```

If the TCA8418 didn't probe, the DT node came over with the graft — check
`i2cdetect` sees its address (Stage 01 notes) before doubting the driver.

### 2. Load the harvested console keymap

```sh
doas mkdir -p /usr/share/keymaps
doas cp harvest/keymaps/tca8418_keypad_m5stack_keymap.map /usr/share/keymaps/
loadkeys /usr/share/keymaps/tca8418_keypad_m5stack_keymap.map
# type test: / should now be SYM+N (per the printed legends), not SYM+9
```

### 3. Make it permanent

Extend `/etc/local.d/console.start` (from Stage 03) — order matters, the
R3 blank/unblank goes **after** both loads:

```sh
#!/bin/sh
loadkeys /usr/share/keymaps/tca8418_keypad_m5stack_keymap.map
setfont cpz-spleen-5x8
echo 1 > /sys/class/graphics/fb0/blank
echo 0 > /sys/class/graphics/fb0/blank
```

- [ ] Reboot test: keymap + font applied with no blank-screen race.

### 4. triggerhappy (hotkey daemon)

```sh
doas apk add triggerhappy        # verify package name (docs/03 §7 note)
doas rc-update add thd default
# /etc/triggerhappy/triggers.d/cpz.conf — exact keycodes chosen in Stage 06
# once the power/shutdown combo is picked, e.g.:
#   KEY_F1    1   doas /sbin/poweroff
```

We only *install and enable* here; the actual bindings (power-off combo,
desktop toggle) get decided in S06/S08 once we know which keycodes the
matrix emits.

### 5. Full key sweep (the gate)

Type the complete printed legend set on the console:

- [ ] A–Z, 0–9, punctuation
- [ ] every blue SYM symbol (all printed combos)
- [ ] Shift behavior, Ctrl, Alt where printed
- [ ] Enter, Backspace, arrows
- [ ] `showkey` on the raw scancodes for anything dead — if a legend is
      wrong *in the stock map too*, that's a stock bug: fix the `.map`
      ourselves and note it in docs/01 row 8

## Files produced

`/usr/share/keymaps/tca8418_*.map` · updated `console.start` · thd enabled

## Acceptance gate

- [ ] Full 46-key sweep passes (console)
- [ ] SYM layer matches printed legends exactly
- [ ] Reboot-stable (local.d ordering correct, no blank race)
- [ ] `thd` running, no bindings yet (S06/S08 add them)

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| `loadkeys` rejects the stock `.map` (format quirks) | convert via `ckbcomp`-style fixup or hand-edit the map — it's a text file; keep ours in `rootfs-overlay/` |
| triggerhappy not packaged in pinned Alpine | tiny C daemon — vendor it into `packages/cpz` (S10) or use a small evdev shell script as stopgap |
| Wayland/desktop xkb mapping | out of scope here (docs/05 §4): the desktop session lives on HDMI with USB keyboards; CPZ-native xkb is optional polish later |
