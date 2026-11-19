# Stage 10 — Reproducible builds & custom packages

> Phase IV · depends on: all previous stages · effort: 6–10 h · status: **not started**
> **This is Gate G4: the project stops being "a configured SD card" and
> becomes an OS you can rebuild from scratch."**

## Goal

`./build/build-image.sh` on a clean checkout produces
`images/cpz-alpine-<ver>.img.gz` — bootable, all stages' features baked in,
checksummed. Everything hand-configured during Stages 02–09 is captured in
`rootfs-overlay/` + `build/` + `packages/cpz/`, so nothing lives only on the
SD card.

## Steps

### 1. Freeze the golden configuration

- [ ] Diff the working lab SD against a stock Alpine sys install → every
      changed/added file moves into `rootfs-overlay/`:
      - `/etc/mkinitfs/mkinitfs.conf`, `/etc/local.d/console.start`,
        `/etc/profile.d/cpz-status.sh`
      - keymap + font files, wpa/interfaces/udev rules, `/etc/cpz/*`,
        sway config, `cpz-desktop*` scripts, init units
- [ ] `config.txt`/`cmdline.txt` final contents → `build/boot/` (both GPU
  profiles, see docs/05 §3)

### 2. Build scripts (`build/`)

```
build/
├── 00-fetch.sh    # pin + verify alpine image, apk index, harvest bundle
├── 10-rootfs.sh   # debootstrap-style: apk --root <dir> add $(cat world)
│                  #   + qemu-user-static chroot for post-install hooks
│                  #   + copy rootfs-overlay/ over it
├── 20-kernel.sh   # Phase A: graft stock kernel8.img + modules from harvest
│                  # Phase B: apk linux-rpi (if Stage 09 cleared it)
│                  # Phase C: abuild packages/cpz/linux-cpz (R1 path)
├── 30-image.sh    # partition (FAT32 p1 + ext4 p2), copy boot files,
│                  #   dump rootfs, fsck, sha256, compress → images/
└── build-image.sh # orchestrates 00→30 with one command + version stamp
```

- [ ] Host requirements documented at top of each script (docs assume any
      Linux host; qemu-user-static for the aarch64 chroot)
- [ ] Every script is `set -euo pipefail`-strict and idempotent

### 3. Custom packages (`packages/cpz/`, aports-overlay style)

For anything that deserves to be a real Alpine package rather than a loose
overlay file:

| Package | Contents |
|---|---|
| `cpz-keymaps` | TCA8418 console keymap (+ optional xkb map later) |
| `cpz-console` | Spleen 5×8 PSF font + `console.start` local.d unit |
| `cpz-desktop` | sway config, wrapper, init oneshot, udev rule, profile switcher |
| `cpz-tools` | status/prompt helpers, grove/bus helpers, benchmark scripts |
| `linux-cpz` | **Phase C only (R1):** raspberrypi/linux + M5's GPL patches; else omitted |

- [ ] Each APKB builds via `apk build`/`abuild` with checksums; a local
      repo key signs them; `10-rootfs.sh` adds the local repo
- [ ] **Phase B/C final decision recorded** (PLAN §5): if Stage 09's probe
      checklist let us move to apk's `linux-rpi`, this is where it gets
      baked in; if ES8389 (or panel) forced Phase C, `linux-cpz` gets built
      here and becomes the default kernel

### 4. Reproducibility gate

```sh
./build/build-image.sh            # run #1 → flash LAB card → full runbook
./build/build-image.sh            # run #2 → flash → full runbook again
```

- [ ] Both runs boot and pass docs/06 §1 + §3 + §4
- [ ] Compare rootfs trees (rsync --dry-run checksum mode): differences
      limited to timestamps/mtimes — or pin further, stretch goal
- [ ] `images/cpz-alpine-<ver>.img.gz` + `.sha256` + CHANGELOG entry

### 5. Update policy (the maintenance story)

- [ ] Userland: `apk upgrade` on the device, safe by construction
- [ ] Kernel bump: re-run `20-kernel.sh` (it re-grafts DTB + firmware per
      the harvest bundle — automated, no hand-steps)
- [ ] Alpine release bump: re-pin in `00-fetch.sh`, re-run everything,
      regression — a weekend, not a crisis
- [ ] Harvest bundle stays in `images/`-adjacent cold storage: it's the
      board's datasheet forever

## Files produced

`build/` scripts · `packages/cpz/*` APKBs · signed local repo · versioned
images + checksums · CHANGELOG.md

## Acceptance gate (G4)

- [ ] Clean-checkout `build-image.sh` → bootable image, twice, both
      passing the full runbook (docs/06 §6)
- [ ] No configuration exists only on the SD card (overlay is the source
      of truth)
- [ ] Kernel strategy end-state recorded in PLAN §5 (A/B/C — with the
      ES8389 outcome)
- [ ] Version 0.1.0 tagged; the definition of done (PLAN §9) is checkable
      from evidence in `images/` + docs/06 records

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| qemu-user chroot quirks (post-install scripts) | build the rootfs *on the device* once, tar it as the golden seed; script still reproducible-ish, document honestly |
| Phase C kernel build complexity (M5 patches don't apply cleanly to a newer rpi kernel) | stay on M5's patch baseline version (Phase A semantics, apk-wrapped) — hardware working beats kernel freshness |
| mkinitfs inside chroot needs /proc mounts | standard qemu-chroot mounts in `10-rootfs.sh`; well-documented pattern |
