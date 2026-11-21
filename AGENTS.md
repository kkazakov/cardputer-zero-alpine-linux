# AGENTS.md — working rules and state for agents (and humans) on this repo

This project builds a bootable Alpine Linux OS image for the M5Stack
CardputerZero. Everything in **Process** is mandatory, not advice. The
**State** and **Traps** sections are the accumulated field knowledge —
read them before touching anything.

Current release: **v0.21.6** (base repo `main`; the launcher fork is a
sibling checkout in `launcher/`, branch `alpine`). v0.20.0 added Files
and Camera as default launcher apps; v0.20.1 fixes MIPI-CSI camera
startup and opens Files in `/home/cpz`; v0.21.0 makes `/cfg` (CPZDATA)
cover the whole card on every flash route, including Windows/macOS/Etcher
ones; v0.21.1 installs `shadow` so `passwd` works as `cpz`; v0.21.2
preserves root/cpz password changes across a reflash; v0.21.3 adds the
optional Tailscale on/off app (hidden until installed + logged in) and
keeps the node logged in across a reflash; v0.21.4 stops the boot restore
from rolling `/var/lib/applaunch` back to the last hourly snapshot, so an
OFF Tailscale/HDMI switch stays off after a reboot; v0.21.5 fixes
`flash-cpz.sh` on `mmcblk`/`nvme` card readers (it looked for
`/dev/mmcblk03` instead of `/dev/mmcblk0p3` and skipped the CPZDATA
format); v0.21.6 makes persistence keep up with setup (5-minute cron,
NetworkManager connect, Tailscale toggle, shutdown) and stops the flasher
from formatting a dirty-but-valid `CPZDATA`.

---

# Process

## Versioning — every functional change carries a version

1. Every functional change (fix, feature, config change) **must bump the
   version** in exactly two places, kept in sync:
   - `build/30-image.sh` → `VER=x.y.z`
   - `rootfs-overlay/etc/cpz-release` → `VERSION="x.y.z"` + a one-line
     `NOTES=` summarizing what changed
2. The git commit that lands the change **must reference that version**
   in its subject:
   ```
   v0.18.3: fix <what>, verified <how>
   ```
3. The built image file name, `cpz-alpine-x.y.z.img.gz`, and its
   `.sha256` must match the committed version. Never ship an image whose
   number does not appear in the log.
4. Docs-only commits (like this file) do **not** bump the version; use
   `docs: ...`.

## Two repositories, both get committed

| Repo | Path | Branch | Notes |
|---|---|---|---|
| base image repo | this checkout | **`main`** | pipeline, overlay, boot config, docs |
| launcher fork | `launcher/` | **`alpine`** | APPLaunch fork; `master` must stay upstream-identical (`fd71a2d`), every local change on `alpine` |

- The launcher fork's upstream is
  `github.com/CardputerZero/launcher` (git remote `upstream`);
  `origin` is `github.com/kkazakov/cardputer-zero-launcher-alpine`.
- `SDK/`, `projects/Calculator`, `projects/CardputerZero-Emulator/lib/lvgl`
  are submodules: never commit pointer drift, never edit inside them in
  this repo (Calculator is patched at build time instead — see below).

## Sessions end with commit + push — no exceptions

After **every fix session** (as soon as a change is verified on hardware
or at least passes the image verification pass), commit and push **both**
repos that changed. Do not leave verified fixes uncommitted or commits
unpushed. Mid-work sessions: commit WIP with `wip:` and no version bump.

**The push route that works** (the desktop holds the GitHub auth as an
SSH key; `build/push-remote.sh` builds a bundle but its clone pushes over
HTTPS and fails with `could not read Username`):

```sh
# from this repo
git bundle create /tmp/base.bundle --all
# from ../launcher (branch alpine), same idea
git bundle create /tmp/launcher.bundle --all
scp /tmp/base.bundle /tmp/launcher.bundle wasp@192.168.88.158:/tmp/

ssh wasp@192.168.88.158 '
  rm -rf /tmp/cb /tmp/cl
  git clone -q /tmp/base.bundle /tmp/cb && cd /tmp/cb &&
    git remote set-url origin git@github.com:kkazakov/cardputer-zero-alpine-linux.git &&
    git push -q origin HEAD:main
  git clone -q /tmp/launcher.bundle /tmp/cl && cd /tmp/cl &&
    git remote set-url origin git@github.com:kkazakov/cardputer-zero-launcher-alpine.git &&
    git push -q origin alpine
'
```

**Branch trap**: the base repo's remote branch is **`main`**, not
`master` (a `HEAD:master` push creates a stray branch — that happened,
and was deleted).

## Build + verify before you commit

```
sh build/20-rootfs.sh          # arm64 container: Alpine rootfs + overlay + launcher install
sh build/30-image.sh           # partitions, FAT boot, ext4 root, verification
```

- `build/verification-report.txt` must contain **zero** `FAIL:` lines
  (`grep -c '^FAIL'`). It is a gitignored build artifact; the checks
  themselves live in `30-image.sh`.
- `20-rootfs.sh` also runs `build/25-launcher.sh`: it rebuilds APPLaunch
  inside the persistent `cpz-launcher-build` container, installs the
  binary/resource tree into `/usr/share/APPLaunch`, copies
  `launcher/deploy/alpine/applaunch.initd|confd`, and adds the OpenRC
  service. Always run the launcher build through this path so the image
  and the fork stay in sync.

## Flashing + persistence

Three ways to write a card, in order of preference:

1. `build/flash-cpz.sh` (Linux) — writes p1/p2, creates CPZDATA at the fixed
   4 GiB offset, formats it only when absent/corrupt, and grows the ext4
   filesystem to the partition offline. Preserves `/cfg` across reflashes.
   **The recommended path.**
2. Raw `dd` / Raspberry Pi Imager / balenaEtcher — writes only p1/p2. The
   device then creates CPZDATA itself on the first boot (`cpz-grow.start`:
   append the partition entry, reboot once, format it). One extra reboot,
   no desktop required.
3. `flash-cpz.bat` / `flash-cpz.command` (Windows/macOS, in the release ZIP)
   — same as 2, plus they restore the card's existing CPZ partition table
   after the write so `/cfg` survives a reflash from Windows/macOS too.

So: **every** flash route now ends up with a `/cfg` that covers the whole
card. The card size is fixed at flash time — CPZDATA is sized to the end of
the card, not grown later on the device — and a CPZDATA filesystem smaller
than its partition (a card that was flashed on a smaller card) is grown on
the next boot.

What survives a reflash (see `rootfs-overlay/usr/local/bin/cpz-save` /
`cpz-restore.start`):

- pass A (user-is-king): `/root`, `/home/cpz`, dropbear hosts+keys,
  `/etc/wpa_supplicant`, `/etc/hostname`, `/etc/hosts`, **the whole
  NetworkManager config tree** (`/etc/NetworkManager` — connection
  profiles incl. launcher-UI ones, plus `NetworkManager.conf`,
  `conf.d/` and `dispatcher.d/`), **`/var/lib/applaunch`**
  (launcher config, HDMI/Tailscale preferences), **`/var/lib/tailscale`**
  (optional Tailscale node key + login profiles, so the node is not
  re-authenticated after a reflash)
  - v0.21.4 exception for `/var/lib/applaunch`: it is **live state**, not
    a saved setting. On a normal boot the running files win; the archive
    only fills it when the directory is empty (fresh flash). See the
    v0.21.4 trap below.
- pass B (additive): `/etc/local.d`, `/etc/conf.d`, `/etc/apk/world`,
  NetworkManager global config not shipped by the new image
- narrow merge (v0.21.2): only the `root` and `cpz` lines of
  `/etc/shadow`, stored 0600 as `/cfg/shadow-users` and merged by name at
  boot. Other accounts always come from the new image. `cpz-save` must
  have run after the password change — the hourly job does it. This is not
  retroactive: a password changed on an older image was never written to
  `/cfg`, so the first v0.21.2 boot still has the build-time `alpine`
  password; set it again and save.

Only `.deb`/store-installed applications are *not* persisted (they belong
in the image or a bundle). Since v0.21.6 `cpz-save` runs every 5 minutes,
on a NetworkManager connect, after a Tailscale toggle and at shutdown;
before that it was hourly, so a setup session followed by a reflash lost
everything newer than the last run.

v0.19.0 note: the restore was silently broken until then — see the
Persistence trap below. "It's in the save list" is not proof it comes
back; run the two-script simulation against a fake `/cfg` before trusting
a persistence change.

## Copying artifacts to the desktop machine

**Every user-facing artifact lands in `~/Downloads/cpz/`** on the
desktop (`wasp@192.168.88.158`, the machine with the SD reader). The
sandbox already has an SSH key for the desktop, so direct `scp` works:

```sh
scp images/cpz-alpine-X.Y.Z.img.gz images/cpz-alpine-X.Y.Z.img.gz.sha256 \
    build/flash-cpz.sh wasp@192.168.88.158:Downloads/cpz/
ssh wasp@192.168.88.158 'cd ~/Downloads/cpz && sha256sum -c cpz-alpine-X.Y.Z.img.gz.sha256 \
  && ls -t cpz-alpine-*.img.gz | tail -n +2 | xargs -r rm -f'   # keep only newest
```

Also ship `docs/FLASH-AND-TEST.md` when it changed. The `cpz-xfer`
container (with `/tmp/k`) is the fallback route if the sandbox key is
missing. Never copy keys, credentials or `build/wifi-secret/`.

## GitHub releases — when the user requests a new release

The canonical release page is
<https://github.com/kkazakov/cardputer-zero-alpine-linux/releases>
(GitHub's **Releases** area; there is no `releases/` directory in git).
A release is a **tag plus uploaded ZIP assets**, not a commit of binaries.

Only release after the image verification is clean and the version commit
is pushed. Then:

1. Write `docs/RELEASE-NOTES-vX.Y.Z.md` with three explicit sections:
   **What's new**, **Known issues**, **Untested / needs a hardware pass**.
   Do not claim untested hardware works.
2. Package:
   ```sh
   sh build/release.sh X.Y.Z
   ```
   This creates `images/cpz-alpine-X.Y.Z.zip` and `.zip.sha256`. The ZIP
   has one top-level folder, `cpz-alpine-X.Y.Z/`, containing:
   - `cpz-alpine-X.Y.Z.img.gz` + `.img.gz.sha256`
   - `flash-cpz.sh` (Linux, preserves `/cfg`)
   - `flash-cpz.bat` + `flash-cpz.ps1` (Windows)
   - `flash-cpz.command` (macOS)
   - `README.txt` and `RELEASE-NOTES.txt`
3. Commit and push the release notes/scripts change first. The release tag
   must point at the pushed `main` commit that contains them.
4. Copy the ZIP, ZIP checksum, release notes and runbook to the desktop,
   then create the GitHub release from the desktop (it holds the `gh`
   auth; the sandbox does not):
   ```sh
   scp images/cpz-alpine-X.Y.Z.zip images/cpz-alpine-X.Y.Z.zip.sha256 \
       docs/RELEASE-NOTES-vX.Y.Z.md docs/FLASH-AND-TEST.md \
       wasp@192.168.88.158:Downloads/cpz/
   ssh wasp@192.168.88.158 'cd ~/Downloads/cpz &&
     gh release create vX.Y.Z --repo kkazakov/cardputer-zero-alpine-linux \
       --target main --title "CPZ-Alpine vX.Y.Z" \
       --notes-file RELEASE-NOTES-vX.Y.Z.md \
       cpz-alpine-X.Y.Z.zip cpz-alpine-X.Y.Z.zip.sha256'
   ```
   `gh release create` creates the `vX.Y.Z` tag at remote `main`.
   Verify with `gh release view vX.Y.Z --repo ...`.
5. Never replace an already-published asset in place. If the release is
   wrong, bump the patch version, rebuild, and publish a new tag. Do not
   commit `images/*.zip` or the release staging directory.

The ZIP is the user-facing download; the raw image alone is not a
complete release. The latest ZIP should also replace the loose image in
`~/Downloads/cpz/` as the artifact kept there.

---

# State (v0.21.6)

## What the image is

- Alpine Linux 3.24 aarch64/musl, OpenRC, kernel 6.18.33+rpt-rpi-v8
  (M5 stock graft, see `build/INPUTS.md`).
- APPLaunch launcher (fork, musl) owns the internal 320×170 ST7789 panel
  (`/dev/fb1`); Calculator, Files and Camera are the other app binaries.
- **No app store, no demo games, no Python terminal.** Home carousel:
  Settings, CLI, SSH, IP Panel, Files, Camera, Calculator, **HDMI**, and
  **Tailscale** only when the optional package is installed and the node
  is logged in.
- Files starts in `/home/cpz`; Camera stills go to
  `~/Pictures/DCIM/Camera`, clips to `~/Videos/Camera`. All of it lives
  under `/home/cpz`, so the `/cfg` snapshot preserves it across reflashes.
- Network: NetworkManager (`nmcli`) owns eth0/wlan0; packages
  `networkmanager networkmanager-wifi networkmanager-cli wpa_supplicant`.
- Desktop: on-demand sway/waybar on HDMI, started only by `cpz-desktop`
  (or the launcher's HDMI app).
- **HDMI is dark until a desktop session starts.** `cmdline.txt` has
  only `console=serial0,115200`; `inittab` has only a ttyS0 getty; no VT
  getty; `disable_splash=1` in `config.txt`. Serial (115200, 14-pin bus)
  is the local rescue console; SSH is the normal remote path.

## User model: the launcher runs as `cpz`

- OpenRC service: `command_user="cpz:cpz"`, `HOME=/home/cpz`,
  `directory=/usr/share/APPLaunch`, logs to `/var/log/applaunch.log`.
- `cpz` groups: `wheel video input audio i2c seat`; passwordless sudo
  (`/etc/sudoers.d/cpz`, 0440, `cpz ALL=(ALL) NOPASSWD: ALL`).
- udev rules `99-cpz-device-groups.rules`: `i2c-*` and `rtc*` →
  group `i2c` 0660; sound nodes → group `audio` 0660; `dma_heap` nodes →
  group `video` 0660 (Camera frame buffers). (udev's stock
  `SUBSYSTEM=="graphics" GROUP="video"` covers `/dev/fb1`.)
- `/var/lib/applaunch` is owned by `cpz`; `cpz-restore.start` re-owns it
  after extracting the root-created `/cfg` archive.
- Power actions: upstream hardwired `systemctl`; the launcher fork now
  uses the sysvinit verbs (via `sudo -n` when unprivileged).

## The HDMI app and `cpz-desktop`

- Launcher page `main/ui/page_app/ui_app_hdmi.{hpp,cpp}`:
  single switch, live state polled from `pgrep -x sway`, ENTER toggles,
  ESC returns home, 44 px `hdmi_100.png` icon.
- It persists `/var/lib/applaunch/hdmi-desktop` (`1`/`0`) and runs
  `sudo -n /usr/local/bin/cpz-desktop start|stop` in the background.
- Boot hook `rootfs-overlay/etc/local.d/cpz-hdmi-boot.start` re-applies
  the preference (runs as root in the `local` service).
- `cpz-desktop` works for root **and** cpz: privileged steps via
  `sudo -n` (seatd, `/run/user/1000`, `/etc/asound.conf`), the sway
  session always runs as cpz, `LIBSEAT_BACKEND=seatd`, waits for
  `/run/seatd.sock`, clears zombie seatd pidfiles, detaches with
  `setsid`.

## The Tailscale app and `cpz-tailscale`

- Tailscale is **not** in the image. The user installs it on the device:
  `apk add tailscale tailscale-openrc`, then `tailscale up`. The service
  is `/etc/init.d/tailscale` (name `tailscale`, **not** `tailscaled`).
- Launcher page `main/ui/page_app/ui_app_tailscale.{hpp,cpp}`: single
  switch, state polled from `pidof tailscaled` (see the busybox trap
  below), ENTER toggles, ESC returns home, 44 px `tailscale_100.png` icon.
- It persists `/var/lib/applaunch/tailscale` (`1`/`0`) and runs
  `sudo -n /usr/local/bin/cpz-tailscale apply on|off` in the background.
  `apply` does **not** write the preference (the page owns it) so a slow
  helper cannot resurrect an older toggle.
- **Visibility is conditional**: `AppDescriptor::available` in
  `builtin_app_registry.cpp` calls `cpz-tailscale available`, which is
  true only when the daemon binary + init script exist AND
  `/var/lib/tailscale/tailscaled.state` has a non-empty `_profiles`
  (i.e. `tailscale up` completed). `Launch` re-polls the predicate every
  20 s and rebuilds the carousel when it flips, so a post-reflash apk
  reinstall makes the card appear without restarting the launcher.
  Settings → Launcher hides the toggle under the same condition.
- `cpz-tailscale` also owns the runlevel: ON adds `tailscale` to
  `default` and starts it; OFF removes the link **first** and then stops
  it. Removing the link is what makes OFF survive a reboot — OpenRC
  starts default-runlevel services before `/etc/local.d` runs, so a boot
  hook alone would reconnect for the first seconds of every boot.
- Boot hook `rootfs-overlay/etc/local.d/cpz-tailscale-boot.start` runs
  `cpz-tailscale boot`, which reads the preference and re-applies it. If
  the package is still being reinstalled by `cpz-wifi.start`, it waits in
  the background (bounded, 3 min) instead of blocking boot.
- `/var/lib/tailscale` (node key + login profiles) is in `cpz-save` and
  restored through pass A, so a reflash does not require re-auth. It is
  0700 root and carries secrets just like the Wi-Fi PSKs.

## Lock screen

- Alpine artwork replaces `share/images/lockscreen.png`
  (320×150 = the application area under the 20 px status bar; the home
  screen keeps the stock background).
- Lock states: full-screen black → any key wakes to the wallpaper →
  TAB arms → ENTER unlocks (ESC back to black). The wallpaper is cached
  in the running process — restart `applaunch` after replacing it.

## Launcher fork changes on `alpine` (cumulative)

Removed: AppStore, demo projects, Python entry, Snake/Tank games,
`.deb`/systemd packaging, non-English READMEs.

Added/fixed (all in `launcher/`):
- musl port of `cp0_lvgl`: condvar wake instead of `sem_clockwait`,
  `InitOnce` mutex rewrite, `settimeofday` fallback, freetype pkg-config.
- Alpine gating in Settings (Software/ADB hidden).
- Calculator native FBDEV/EVDEV patch
  (`deploy/alpine/patches/calculator-native-fbdev.patch`, applied by
  `build/25-launcher.sh`).
- ALSA volume fallback (`amixer DACL/DACR`) when libpulse is absent.
- HDMI app, Alpine lock-screen art, sysvinit power commands.
- Tailscale tunnel toggle page + `AppDescriptor::available` conditional
  registration (hidden until installed and logged in), plus the
  `Launch` availability re-poll that makes the card appear at runtime.
- `deploy/alpine/applaunch.initd|confd` (cpz user, log ownership).

---

# Traps (field-learned — do not re-learn these)

### Users / authentication
- **Alpine's busybox is NOT setuid** (`-rwxr-xr-x` on 3.24), so its
  `passwd` applet fails for a normal user: `passwd: must be suid to work
  properly`. Root still succeeds, which is why the build's `chpasswd`
  never exposed it. Do not "fix" this with `chmod u+s /bin/busybox` — all
  applets would run privileged. The image ships the `shadow` package:
  `/usr/bin/passwd` is 4755 root:root and uses PAM
  (`/etc/pam.d/shadow-utils`). Verify with
  `stat -c '%a %U:%G' /usr/bin/passwd` → `4755 root:root` and a test as
  cpz, **not** as root (root works even with busybox).
- `cpz` has NOPASSWD sudo, so the admin reset path is
  `sudo -n passwd cpz` (or `... root`). Do not add a shell wrapper named
  `passwd`: a script cannot be setuid, and sudo would just run the wrapper.
- `/etc/shadow` is **not** archived wholesale. v0.21.2 saves only the
  `root` and `cpz` lines to a 0600 `/cfg/shadow-users`; `cpz-restore.start`
  merges them by name and leaves every other account to the new image.
  Do not "simplify" this to `etc/shadow` in `PASS_A`: that resurrects
  stale users and lock/expiry state from an older image. Test the merge
  with a fake `/cfg` — the image itself is aarch64 and cannot run here.

### OpenRC / service
- **start-stop-daemon switches to `command_user` BEFORE opening
  `output_log`/`error_log`.** A root-owned log makes the start fail with
  `unable to open the logfile for stdout: Permission denied`, no process
  is exec'd, OpenRC leaves a stale pidfile and reports `crashed` — a
  black LCD with a healthy binary and an empty log. `start_pre` must
  `chown cpz:cpz` + `chmod 0664` the log (v0.18.1).
- After modifying the init script: `rc-service applaunch stop`,
  `rm -f /run/applaunch.pid`, then start; `status` caches the old state.
- `systemctl` does not exist; use `reboot`/`poweroff` (busybox), via
  `sudo -n` for cpz.

### Tailscale (optional package, v0.21.3)
- **The service is `tailscale`, not `tailscaled`.** Alpine's
  `tailscale-openrc` ships `/etc/init.d/tailscale`; `rc-service tailscaled`
  reports "service does not exist" while the daemon runs fine. The
  *process* is `tailscaled`, which is what the launcher polls.
- **`pgrep -x tailscaled` returns nothing on busybox** even while the
  daemon runs: busybox applies `-x` to argv[0], and the init script runs
  `/usr/sbin/tailscaled`. Use `pidof tailscaled` (basename match). Do not
  "fix" this by adding `-f`, which would then compare the whole command
  line.
- **`tailscale status` is not a visibility test.** It needs the running
  daemon, and the launcher card must stay visible while the tunnel is
  OFF. Use the saved login state instead: `tailscaled.state` has a
  non-empty `_profiles` only after `tailscale up` completed.
- **`/var/lib/tailscale` is 0700**, so cpz cannot read the state file.
  Every availability decision goes through `cpz-tailscale available`
  under `sudo -n`; a `[ -f ... ]` in the launcher always returns false.
- **OFF must delete the default-runlevel link.** OpenRC starts every
  default service before `/etc/local.d` runs, so a hook that only calls
  `rc-service tailscale stop` lets the node reconnect for the first
  seconds of every boot (and, worse, the link survives a reflash in
  `/etc/runlevels` only if the image shipped it — it does not).
- The helper must not write the preference on `apply`: the launcher page
  owns `/var/lib/applaunch/tailscale`, and a slow background helper that
  wrote it could resurrect the previous toggle.
- `apk add tailscale` adds it to `/etc/apk/world`, which pass B restores,
  and `cpz-wifi.start` reinstalls `/cfg/pkglist.txt` in the **background**
  at boot. The boot hook therefore has to tolerate "package not there
  yet" and retry — it must not block the boot waiting.

### cp0 process API
- `RunArgv`'s second argument is the **background flag parsed by
  `parse_bool()`, which accepts only `0`/`1`**. Passing `"true"` makes
  the whole request invalid and silently does nothing (that was the HDMI
  app's "stays on Starting…" bug). Use `{"RunArgv", "1", ...}`.
- Use `CaptureArgv` for output (`pgrep`, `amixer sget`), `RunArgv 0` to
  wait, `RunArgv 1` to detach (child redirects to `/dev/null`).
- Sudo paths: `cp0_signal_sudo_*` / `cp0_process_commands::run_sudo`
  invoke `sudo -k -S --`; NOPASSWD makes it work without a password.

### LVGL 9.5 (launcher UI)
- `LV_PART_INDICATOR` on `lv_switch` is the **whole track** and does not
  change colour with state — set the off colour on `LV_PART_INDICATOR`
  and the on colour on `LV_PART_INDICATOR | LV_STATE_CHECKED`; the knob
  is a white circle.
- Scaled images keep their **unscaled layout box**: after
  `lv_image_set_scale(img, n)` always `lv_obj_set_size(img, w, h)` to
  the displayed size, or the 100×100 box overlaps neighbours.
- The Montserrat subsets lack `LV_SYMBOL_BULLET`, em dashes and the
  ellipsis — they render as boxes. Use ASCII and real `lv_obj` dots.
- The global status bar already shows `set_page_title()`; do not draw a
  second header inside a page.
- Page key handling goes on `root_screen_` (`LV_EVENT_KEY`); call
  `navigate_home()` for ESC. Do not add the switch to a group; toggle it
  from the key handler and send `LV_EVENT_VALUE_CHANGED`.

### Build/environment
- Docker bind mounts use the **daemon's** paths (`REPO_HOST`), and the
  builder sees the host repo at `/repo`; the launcher is `/repo/launcher`.
- No `python3` on the sandbox; use `cpz-launcher-build` (it has
  python3 + Pillow + pypng now). `dpkg`/`dpkg-deb` exist in that
  container; there is no `apt` on Alpine.
- Image asset checks in `30-image.sh` compare against
  `/repo/launcher/...` — keep that path in mind when moving files.

### Field debugging
- Device: `192.168.88.67`, root/`alpine`. The sandbox key is
  `~/.ssh/id_ed25519_cpz` (comment `cpz-agent`), installed in
  `/root/.ssh/authorized_keys`. **A reflash wipes it** — re-provision
  via the `cpz-xfer` container (`sshpass -p alpine ssh ...`) then append
  the key.
- `scp` to the device does **not** work (no sftp-server): use
  `cat file | ssh ... 'cat > /path'`.
- **LCD screenshots**: `dd if=/dev/fb1 bs=108800 count=1` (320×170×2,
  RGB565 little-endian), convert with a few lines of Python in
  `cpz-launcher-build`, then view the PNG. `fb0` is HDMI and shows the
  legacy console buffer, not sway.
- No automation RPC is compiled in, so keys cannot be injected remotely.
  For a screenshot of a page, a temporary `CPZ_OPEN_PAGE=hdmi`
  env hook existed during development — re-add it locally if needed,
  but never ship it (it was removed before v0.18.3).
- Hot-patch loop for UI work: stop `applaunch`, copy the freshly built
  `dist/M5CardputerZero-APPLaunch` over `/usr/share/APPLaunch/bin/…`
  (`cat | ssh 'cat >'`), restart the service, capture `/dev/fb1`.
- Launcher log: `/var/log/applaunch.log` (now captures stdout+stderr,
  owned `cpz:cpz`).
- **Camera "MIPI-CSI camera unavailable"** has three independent causes,
  all fixed in v0.20.1: `/dev/dma_heap/*` is `0600 root:root` (udev rule
  must put it in `video`), Alpine's `libcamera` package lacks the RPi VC4
  IPA (`libcamera-ipa`) and `imx219.json` tuning/proxy
  (`libcamera-raspberrypi`), and Camera 1.0.2 refuses to start without
  `rpi_apps.yaml` under `/usr/share/libcamera/pipeline/rpi/vc4/`.
  Verify from `/var/log/applaunch.log`: it should log
  `Using rpicam-apps pipeline configuration`, `Adding camera ... imx219`
  and `Camera backend selected: libcamera`.

### Persistence (`cpz-save` / `cpz-restore.start`)
- **Alpine's only tar is busybox, and it ABORTS the whole extraction at
  the first error** — including `-k`'s "File exists". `tar -k` therefore
  does *not* mean "skip this file and keep going": one image file kills
  the run, and every later member is silently lost. That is how v0.14–
  v0.18.3 lost restored NM profiles/config while claiming otherwise
  (also, `-xzpkf` hides a `k` inside the cluster: pass A meant to
  overwrite but was actually keep-old-files). Fix: extract once into an
  empty staging dir, then merge allow-listed paths by hand; pass A
  overwrites, pass B never clobbers an image file.
- The archive holds Wi-Fi PSKs: it is created `0600` (umask 077). Do not
  "simplify" that away, and never widen `/cfg`. `/cfg/shadow-users`
  (v0.21.2) holds password hashes; 0600 is an on-device permission, not
  encryption — a removed card exposes it just like `/etc/shadow`.
- A hardcoded member list plus `tar ... || fail` means one missing
  optional path discards the *entire* snapshot — and the hourly job sends
  output to `/dev/null`, so persistence dies silently. Filter members to
  what exists (v0.19.0).
- The NM reload verb does not exist in Alpine's `/etc/init.d/networkmanager`
  (only `depend()`), so `rc-service networkmanager reload` always failed.
  Use `nmcli connection reload` (SIGUSR1) and only when NM is up.
- Test a persistence change by running both scripts against a fake `/cfg`
  (Docker `-v dir:/cfg`, copy the scripts in) — grepping the save list is
  not evidence that restore works.
- **v0.21.4: `/var/lib/applaunch` is live state, not a saved setting.**
  The old pass A restored it on every boot, so an OFF Tailscale switch
  written after the last hourly save was overwritten with the archive's
  stale `1` and the tunnel came back up after a reboot (same class of bug
  for the HDMI preference and any launcher config). The image ships an
  **empty** `/var/lib/applaunch`; `cpz-restore.start` now skips that member
  when the live directory is non-empty, and only a fresh flash takes the
  archive. Do not "simplify" it back into pass A archive-wins, and do not
  test it by only grepping the script: write `0` to the live preference,
  run `cpz-restore.start` with an archive that holds `1`, and check the
  live file is still `0`.
- **v0.21.6: the save triggers are part of persistence, not a nicety.**
  `cpz-save` used to run only hourly. A user who flashed, joined Wi-Fi,
  installed Tailscale, set a password and reflashed within the hour lost
  every one of those changes (field report: "passwords were reset to
  defaults, SSH config, everything"). It now runs every 5 minutes, on a
  NetworkManager connect, after a Tailscale toggle, and at shutdown
  (`/etc/local.d/cpz-save.stop`), serialized by `/run/cpz-save.lock`.
  Keep all four; the shutdown hook is the one that catches "poweroff,
  then pull the card", and the NM dispatcher catches a freshly joined
  Wi-Fi profile before the first cron tick.
- **v0.21.6: the flasher must not format a valid-but-dirty CPZDATA.**
  `fsck.ext4 -n` returns non-zero for a journal that needs replay; the
  pre-v0.21.6 code read that as corruption and ran `mkfs.ext4`, wiping a
  perfectly good `/cfg` on a reflash after an unclean shutdown. The fix
  is `blkid` says ext4 → `e2fsck -f -y` repair → `fsck -n` verify;
  `mkfs` only when the filesystem is absent/not ext4 or the repair fails.

### Flasher (`flash-cpz.sh`, v0.21.5)
- **Partition names differ by device class.** `/dev/mmcblk0` →
  `/dev/mmcblk0p3`, `/dev/nvme0n1` → `/dev/nvme0n1p3`, but `/dev/sda` →
  `/dev/sda3`. The old `PART="${DEV}3"` built `/dev/mmcblk03`, so after
  writing p1/p2 the script printed `WARNING: /dev/mmcblk03 did not
  appear — persistence unavailable`, **exited 0**, and left p3 as an
  unformatted partition. It only ever worked on `/dev/sdX` USB readers.
  Fix: suffix `p3` when the disk basename ends in a digit, retry `partx`
  for ~3 s, and exit non-zero with the manual `mkfs` line if the node is
  still missing.
- A card flashed by the buggy version is still bootable; finish it with
  `sudo partx -u /dev/mmcblk0 && sudo mkfs.ext4 -F -L CPZDATA
  /dev/mmcblk0p3` (or rerun the fixed flasher).

### CPZDATA card growth (`cpz-grow.start`, v0.21.0)
- **The kernel will not re-read the partition table of a disk whose
  partitions are mounted** (`BLKRRPART` → EBUSY, and `sfdisk` fails the
  same way unless you pass `--no-reread`/`--no-tell-kernel`). So the
  device cannot write the CPZDATA entry *and* resize the filesystem in the
  same boot: state A writes the table, sets a flag and **reboots once**;
  the new geometry is only visible on the next boot. Do not "simplify" the
  reboot away — it is the whole point.
- `sfdisk --append` on a table that still has an old p3 entry **creates an
  overlapping p4**, because append takes the next free slot. Delete p3
  first. The v0.20.1 flasher passed `--no-update`, **which sfdisk does not
  have**, so its `--delete 3` always failed and was hidden by `|| true`.
  Valid flags here are `--no-reread` and `--no-tell-kernel`.
- Never `mkfs` a partition the script did not create. The `/etc/cpz-grow.pending`
  flag is what makes "format the empty CPZDATA we just made" safe; without
  it a card with a foreign filesystem on p3 gets wiped.
- `dumpe2fs -h` prints `Block count:              524288` — the number is
  awk field **`$3`**, not `$2`. `{print $2}` returns the string `count:`,
  the arithmetic comparison then fails and every resize silently does
  nothing. Same trap as `-xzpkf`: it looks correct and does nothing.
- `mkfs.ext4` at boot must be lazy (`-E lazy_itable_init=1,lazy_journal_init=1`),
  otherwise a 32 GiB CPZDATA blocks the boot for minutes.
- Do not test this by reading the script:
  `docker run --privileged -v "$REPO_HOST:/repo" alpine:3.24 sh /repo/build/test-cpz-grow.sh`
  — it fakes `/sys/block/mmcblk0` (the only way to simulate "the kernel
  does not know p3 yet" / "p3 ends before the end of the card"), uses real
  loop devices so `mkfs.ext4`/`resize2fs`/`blkid` really run, and stubs
  `reboot`. Loop devices are shared with the host: always take a brand-new
  minor (`mknod /dev/loopN b 7 N`), never reuse one, and detach your own
  files' devices at the end.

---

# App-store / .deb research (phase 2 context)

The upstream store is gone from the fork, but the apps are relevant:

- The store client (`github.com/CardputerZero/Store`) fetches
  `https://cardputerzero.github.io/generated/registry.json` (schema v2,
  ~121 apps; CN mirror on aliyun). Each entry has
  `download.type: "deb"`, a GitHub release URL
  (`github.com/CardputerZero/packages` → tag `apt-pool`), md5/sha256.
- Install path: download → MD5 verify → `dpkg-deb -f` metadata check →
  `dpkg --install` (fallback `apt-get -y install <deb>`), via a sudo
  helper. **Packages are prebuilt .deb — nothing is built on the device.**
- Typical payload (3 files):
  `/usr/share/APPLaunch/bin/<App>`,
  `/usr/share/APPLaunch/applications/<app>.desktop`,
  `/usr/share/APPLaunch/share/images/<icon>.png`. Camera also installs
  `/usr/bin/camera_app`.
- **They are glibc binaries** (`Depends: libc6, libstdc++6, libgcc-s1`
  plus per-app libs: ffmpeg, libpulse0, libcamera0.8, libfmt10, …), so
  they do not run on Alpine. `gcompat` is not a practical route for
  C++ apps.
- **Rebuild-from-source works.** The official apps are CMake projects
  (`bootstrap.sh` fetches LVGL 9.5, spdlog, smooth_ui_toolkit;
  `packaging/deb/`). Compass was built natively on musl/aarch64 in
  `cpz-launcher-build` with **zero source patches** — the only friction
  was the asset conversion (Pillow/pypng/lz4). APPLaunch integration is
  free: drop the three files in place; the desktop loader picks them up
  within 3 s (add the filename+label to `kManagedDesktopFilenames` /
  `kBuiltInAppOrder` if it should be toggleable).
- Effort estimate: ~0.5 day for one reusable build harness; 1–4 h per
  simple app; 0.5–1 day each for audio (Recorder/Music, libpulse→ALSA),
  Files (ffmpeg); 1–2 days for Camera (libcamera ABI); 0.5–1 day each for
  the Cap-* radio apps. Full official set ≈ 4–7 working days.
- Recommendation: ship Alpine "app bundles" (tar.gz: bin + .desktop +
  icon) rather than .debs; port the Store UI only after the bundle
  pipeline is proven.

---

# Where things are

| Path | Contents |
|---|---|
| `build/` | Pipeline: `20-rootfs.sh`, `25-launcher.sh`, `26-apps.sh`, `30-image.sh`, `flash-cpz.sh`, `release.sh`, `push-remote.sh`, `INPUTS.md` |
| `build/test-cpz-grow.sh` | Container simulation of `cpz-grow.start` (run with `--privileged`) |
| `build/release-assets/` | Windows/macOS flashers packaged into each GitHub release ZIP |
| `docs/RELEASE-README.txt`, `docs/RELEASE-NOTES-v*.md` | release ZIP readme + GitHub release description |
| `build/boot-config/` | `cmdline.txt` (serial-only console), `config.txt` (splash off, overlays) |
| `rootfs-overlay/etc/local.d/` | `cpz-grow.start` (first, alphabetically), `cpz-restore.start`, `cpz-hdmi-boot.start`, `cpz-audio.start`, `cpz-wifi.start`, `cpz-leds.start`, `console.start` |
| `rootfs-overlay/etc/udev/rules.d/` | `99-cpz-device-groups.rules` (i2c/rtc/audio/dma_heap groups) |
| `rootfs-overlay/etc/sudoers.d/cpz` | NOPASSWD grant (forced 0440 by `rootfs-configure.sh`) |
| `rootfs-overlay/usr/local/bin/cpz-desktop` | on-demand HDMI session (root or cpz) |
| `rootfs-overlay/usr/local/bin/cpz-tailscale` | optional Tailscale on/off (runlevel + service + availability) |
| `rootfs-overlay/etc/local.d/cpz-tailscale-boot.start` | re-applies the saved Tailscale preference at boot |
| `rootfs-overlay/usr/local/bin/cpz-save` | persistence snapshot → `/cfg/save.tar.gz` (5-min cron + NM connect + Tailscale toggle + shutdown + manual, lock-serialized) |
| `rootfs-overlay/etc/local.d/cpz-save.stop` | final snapshot at shutdown/reboot |
| `rootfs-overlay/etc/NetworkManager/dispatcher.d/90-cpz-save` | snapshot when a connection comes up/down |
| `rootfs-overlay/etc/cpz/` | `sway.config` (0644), `hdmi-mode` |
| `rootfs-overlay/etc/cpz-release` | version + NOTES |
| `launcher/` | APPLaunch fork, branch `alpine` (see its own `AGENTS.md`) |
| `launcher/deploy/alpine/` | OpenRC unit, conf.d, Calculator patch, runtime packages |
| `harvest/`, `vendor/` | pinned stock BSP and M5 driver/overlay sources |
| `docs/FLASH-AND-TEST.md` | user-facing flash + test runbook |
| `images/` | built images (gitignored) |

## Never commit

- `build/wifi-secret/` — the user's Wi-Fi credentials
- `images/` — regenerated from pinned inputs
- Field captures (`build/cpz-diag-field.txt`, `build/cpz-keys.bin`,
  screenshots) — findings belong in code comments/this file

## House style

- Every fix documents its own history in the file it lands in — real fix
  at top, dead ends listed below (see `cpz-leds.start`). Future agents
  must not re-try documented dead ends.
- Field-verified facts (keycap legends, expander registers, OpenRC
  ordering, font subsets) live in comments where they were discovered.
- Keep the launcher `alpine` diff small and concentrated so upstream
  rebases stay mechanical.
