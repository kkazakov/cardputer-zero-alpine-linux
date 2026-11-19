# Stage 08 — HDMI desktop on demand

> Phase III · depends on: Stages 03, 04, 05 (Stage 07's asound card names) · effort: 4–6 h · status: **not started**
> **This is Gate G3.** Design contract in [docs/05](../docs/05-hdmi-on-demand.md).

## Goal

A Wayland desktop that exists **only on demand**: zero graphical processes at
boot; `cpz-desktop start` (or opt-in HDMI hotplug) produces an HDMI-only
session in ≤10 s; `stop` returns every MB. The LCD console is untouched
throughout.

## Steps

### 1. Install the stack (community repo)

```sh
doas apk add sway seatd foot mesa-dri-gallium wl-clipboard grim font-dejavu
# (verify mesa subpackage actually ships the vc4 Gallium driver: docs/03 §7)
doas adduser cpz seat 2>/dev/null; doas adduser cpz video; doas adduser cpz input
```

- [ ] `apk search` sanity pass for the exact names in the pinned release

### 2. The session config

`/etc/cpz/sway.config` (root-owned, world-readable):

```
# LCD output disabled by *name* — find it first:
#   WLR_BACKENDS=drm swaymsg? no: temporarily run swaymsg -t get_outputs
#   from within a test session and use that exact connector name.
output <LCD-connector> disable
output HDMI-A-1 mode 1920x1080@60Hz

# start the session where a human is:
exec foot
# optional: a clock in the waybar only after RAM measurements allow
```

- [ ] Record the real connector names on this board (LCD name is whatever
      the DT calls it — Stage 01 notes help)
- [ ] Test renderer reality: `WLR_RENDERER=pixman sway` (CPU) vs vc4 —
      decide the console-profile default (llvmpipe per docs/05 §3)

### 3. cpz-desktop wrapper + OpenRC oneshot

`/usr/bin/cpz-desktop` (bash/ash) implementing docs/05 §2–4:

```
start: rc-service seatd start; su - cpz -c "seatd-launch sway -c /etc/cpz/sway.config"
stop : pkill -u cpz sway; rc-service seatd stop; print free -m delta
status: session pgrep + free -m + current profile
```

`/etc/init.d/cpz-desktop` — a trivial oneshot wrapper so udev can call
`rc-service` safely. Keep it **out of any runlevel**: it exists to be
started *on demand*, never at boot (D-list in docs/03 §6).

### 4. udev hotplug hook

`/etc/udev/rules.d/99-cpz-hdmi.rules` (from docs/05 §2) +
`/usr/sbin/cpz-hdmi-event` reading `/etc/cpz/hdmi-mode` (`ask` default):

- [ ] `ask` mode: plug HDMI → notice on the LCD console only. Unplug →
      nothing.
- [ ] `auto` mode: plug → backgrounded `rc-service cpz-desktop start`.
- [ ] The script returns in <1 s (udev `RUN` constraint — spawn, don't work)

### 5. GPU profiles script

`cpz-desktop-profile desktop|console`:

- edits `gpu_mem` (32↔96) + `cma=` (64↔128M) in the boot partition files
- prints "reboot to apply" honestly (docs/05 §3 — no runtime resplit)
- [ ] Both profiles boot-test: console profile → llvmpipe session; desktop
      profile → vc4 GLES + H.264 1080p30 decode (ffmpeg v4l2h264dec)

### 6. Audio routing

Per Stage 07's card names: `/etc/asound.conf.hdmi` and `/etc/asound.conf.es8389`;
`cpz-desktop start/stop` swaps the symlink to `/etc/asound.conf`.

- [ ] Session audio lands on the monitor; stop → back to the device speaker

### 7. RAM accounting (feeds S09)

- [ ] `free -m` before start / after start / after stop, 10× start-stop
      loop, recorded. Target: session ≤ 150 MB console-profile; stop
      returns within 10 MB of pre-start
- [ ] If sway won't fit: **zram** (S09) first, **labwc** swap-in second
      (lighter compositor, same contract), never "drop the on-demand
      desktop" — that's a goal, not a preference

## Files produced

`/etc/cpz/sway.config` · `/usr/bin/cpz-desktop` · init oneshot · udev rule
+ event script · profile switcher · asound conf pair

## Acceptance gate (G3)

- [ ] Cold boot: `pgrep sway` empty; idle RAM ≤ 60 MB (radios on)
- [ ] `start` → usable HDMI session ≤ 10 s; LCD console live the whole time
- [ ] Hotplug: `ask` → console notice; `auto` → session unattended
- [ ] `stop` → RAM reclaimed (≤ +10 MB residual), console intact, 10× loop
      no leaks
- [ ] Desktop profile: vc4 GL + H.264 1080p30 decode passes
- [ ] Audio follows the session; USB keyboard/mouse work in-session

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| sway RAM too heavy at 1080p | labwc (or cage) same contract, lighter; zram first |
| vc4 GL flaky on this kernel | llvmpipe default (docs/05 already assumes it in console profile) |
| udev RUN timeout | script spawns only (`setsid … &`), zero work in the rule |
| seatd/permissions quirks without logind | user in `seat` group + `seatd-launch`; documented pattern, well-trodden on OpenRC systems |
