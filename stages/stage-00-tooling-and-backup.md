# Stage 00 — Tooling & stock backup

> Phase I · depends on: nothing · effort: ~1 h · status: **not started**

## Goal

A safe workbench: the stock OS preserved bit-exact, a second SD card for
experiments, and the repo scaffolded (`harvest/` ignored by git).

## Steps

### 1. Gather hardware

- [ ] CardputerZero (+ stock microSD untouched!)
- [ ] **Second microSD card (≥8 GB, A1/A2 class)** — experiments never run
      on the stock card
- [ ] USB microSD reader for the build host
- [ ] USB-TTL 3.3 V serial adapter + dupont wires (UART console from the
      14-pin bus — the lifeline when the panel and HDMI are both broken)
- [ ] HDMI cable + any monitor (stock console access)
- [ ] USB flash drive + USB keyboard (networking tests later)
- [ ] A Linux build host (any distro; this plan assumes Alpine or
      Debian-family with `sudo`)

### 2. Install host tools

```sh
# Debian/Ubuntu host:
sudo apt install dd dtc parted dosfstools e2fsprogs gzip sha256sum qemu-user-static
# Alpine host:
doas apk add dtc parted dosfstools e2fsprogs tar xz qemu-user-static
# (qemu-user-static is optional until Stage 10 host builds)
```

### 3. Scaffold this repo

```sh
cd /home/wasp/projects/cardputer-zero-alpine
mkdir -p harvest rootfs-overlay build packages/cpz images
cat > .gitignore <<'EOF'
harvest/
images/
*.img
*.img.gz
EOF
git init 2>/dev/null || true
```

### 4. Back up the stock SD — the single most important step

```sh
# insert the STOCK card read-only if your reader supports it (many do)
lsblk                                   # identify the card, e.g. /dev/sdX — TRIPLE CHECK
sudo umount /dev/sdX?* 2>/dev/null      # detach any auto-mounts

sudo dd if=/dev/sdX of=images/cpz-stock-$(date +%F).img \
     bs=4M conv=fsync status=progress
sha256sum images/cpz-stock-*.img > images/cpz-stock-$(date +%F).img.sha256
```

- [ ] Image size matches card size; sha256 recorded; file stored somewhere
      durable too (NAS/another disk) — this is the factory-restore escape
      hatch for the whole project.
- [ ] Optional: also `tar` the FAT32 boot partition contents now (mount a
      loop offset copy) — Stage 01 wants them offline anyway.

### 5. Prepare the experiment card

Nothing to flash yet (Stage 02 does that) — just physically label both
cards: **STOCK** and **LAB**.

## Files produced

`harvest/` (empty), `.gitignore`, `images/cpz-stock-*.img{,.sha256}`

## Acceptance gate

- [ ] Stock image backup exists, size-correct, hash-verified
- [ ] Lab SD card labeled and unused
- [ ] Host tools installed (`dtc`, `dd`, partitioning basics)
- [ ] Repo scaffolded with ignores in place

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| Wrong `/dev/sdX` during `dd` backup (host disk instead of card!) | `lsblk` + check SIZE column matches card size before every `dd` — no exceptions |
| Stock card gets reformatted by accident | that's what the backup is for; still: stock card never goes back in the reader until Stage 01 finishes |
