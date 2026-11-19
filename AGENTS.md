# AGENTS.md — working rules for agents (and humans) on this repo

This project builds a bootable Alpine Linux OS image for the M5Stack
CardputerZero. Everything below is **mandatory process**, not advice.

## Versioning — every functional change carries a version

1. Every functional change (fix, feature, config change) **must bump the
   version** in exactly two places, kept in sync:
   - `build/30-image.sh` → `VER=x.y.z`
   - `rootfs-overlay/etc/cpz-release` → `VERSION="x.y.z"` + a one-line
     `NOTES=` summarizing what changed
2. The git commit that lands the change **must reference that version**
   in its subject:
   ```
   v0.13.0: fix <what>, verified <how>
   ```
3. The built image file name, `cpz-alpine-x.y.z.img.gz`, and its
   `.sha256` must match the committed version. Never ship an image whose
   number does not appear in the log.

## Sessions end with commit + push — no exceptions

After **every fix session** (as soon as a change is verified on
hardware or at least passes the image verification pass):

```
git add -A
git commit -m "v0.x.y: <summary>"
./build/push-remote.sh        # pushes to github via the desktop host
```

Do not leave verified fixes uncommitted, and do not leave commits
unpushed. If a session ends mid-work, commit the WIP with a
`wip:` prefix and **no** version bump.

## Build + verify before you commit

```
sh build/20-rootfs.sh          # arm64 container: Alpine rootfs + overlay
sh build/30-image.sh           # partitions, FAT boot, ext4 root, verify
```

`build/verification-report.txt` must end `verification clean` — every
`FAIL:` line is a blocker. The report is a build artifact (gitignored);
the checks that matter are part of `30-image.sh` itself.

## Flashing + persistence

Flash with `build/flash-cpz.sh` (see README) — it preserves the
`CPZDATA` partition that carries user state across reflashes.
Raw `dd` works too but drops persistence for that flash.

## Copying artifacts to the desktop machine

**Every user-facing artifact lands in exactly one place on the
desktop:**

```
~/Downloads/cpz/
```

| Artifact | Built by | Notes |
|---|---|---|
| `cpz-alpine-X.Y.Z.img.gz` + `.sha256` | `build/30-image.sh` → `images/` | always ship these two together |
| `flash-cpz.sh` | `build/flash-cpz.sh` | keep the desktop copy in sync with the repo |
| `FLASH-AND-TEST.md` | `docs/` | optional, when its content changed |
| device pulls (`camera-test.jpg`, diag files, …) | ad-hoc | same folder, so the user finds everything in one place |

The desktop is the machine with the SD-card reader: user `wasp`,
LAN address `192.168.88.158`. (If this file is ever shared outside
the household, redact that line.)

### The route (build sandbox → desktop)

The workspace runs on the build host; the desktop is separate. Transfers
go through the long-lived `cpz-xfer` container (host network, holds the
transfer SSH key at `/tmp/k` inside it, never in this repo):

```sh
# 1. stage into the transfer container
docker cp images/cpz-alpine-X.Y.Z.img.gz       cpz-xfer:/tmp/
docker cp images/cpz-alpine-X.Y.Z.img.gz.sha256 cpz-xfer:/tmp/

# 2. scp to the desktop
docker exec cpz-xfer sh -c '
  scp -i /tmp/k -o StrictHostKeyChecking=no \
      /tmp/cpz-alpine-X.Y.Z.img.gz /tmp/cpz-alpine-X.Y.Z.img.gz.sha256 \
      wasp@192.168.88.158:Downloads/cpz/'

# 3. verify ON the desktop + drop the previous image (keep only newest)
docker exec cpz-xfer sh -c '
  ssh -i /tmp/k -o StrictHostKeyChecking=no wasp@192.168.88.158 \
    "cd ~/Downloads/cpz && sha256sum -c cpz-alpine-X.Y.Z.img.gz.sha256"'
```

`flash-cpz.sh` picks the newest `cpz-alpine-*.img.gz` by mtime, so old
images left around are harmless but confusing — remove them.

Git pushes use the same route (bundle → scp → push from the desktop,
which holds the GitHub auth): `build/push-remote.sh` with
`PUSH_HOST=wasp@192.168.88.158`, or the manual equivalent in that file.
Never copy keys, credentials or `build/wifi-secret/` along with
artifacts.

## Never commit

- `build/wifi-secret/` — the user's Wi-Fi credentials
- Built images (`images/`) — regenerated from pinned inputs
- Field captures (`build/cpz-diag-field.txt`, `build/cpz-keys.bin`) —
  session data; the useful findings belong in code comments instead

## Where things are

| Path | Contents |
|---|---|
| `build/` | Pipeline: `20-rootfs.sh`, `30-image.sh`, `flash-cpz.sh`, `push-remote.sh`, pinned inputs (`INPUTS.md`) |
| `rootfs-overlay/` | Everything grafted onto Alpine (scripts, config, keymap) |
| `harvest/` | The pinned stock BSP (kernel modules, firmware, boot files) — see `build/INPUTS.md` for provenance and hashes |
| `vendor/` | M5's driver/overlay sources (GPL) used for out-of-tree rebuilds |
| `docs/` | Hardware inventory, flash-and-test runbook |
| `PLAN.md` | Master plan, stages, budgets, decision log |

## House style

- Every fix documents its own history in the file it lands in — see
  `rootfs-overlay/etc/local.d/cpz-leds.start` for the pattern: the real
  fix at top, the dead ends tried before it listed below. Future agents
  must not re-try documented dead ends.
- Field-verified facts (keycap legends, expander registers, rfkill
  behavior) live in comments where they were discovered, not in chat
  logs.
