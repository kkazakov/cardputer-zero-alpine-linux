# 05 — HDMI desktop on demand

## 1. The contract ("on demand only" means exactly this)

1. **At boot, zero graphical processes exist.** No compositor, no seat
   daemon, no GPU buffer allocations beyond the KMS console. `pgrep sway`
   must come up empty — asserted in the S08 gate.
2. The **LCD text console is always the home state** — HDMI activity never
   moves, blanks, or resizes it.
3. A desktop starts only by **explicit user action** (command) or, if the
   user opts in, **HDMI hotplug**. Never by mere boot.
4. The session **stops cleanly**, returning all RAM; the console state is
   untouched.

## 2. Runtime design

```
[HDMI plug] → udev (drm change event, card0-HDMI-A-1)
                └─ /usr/sbin/cpz-hdmi-event (tiny script, reads /etc/cpz/hdmi-mode)
                     ├─ "off"  → do nothing
                     ├─ "ask"  → notice on LCD console: "HDMI detected — cpz-desktop start"
                     └─ "auto" → rc-service cpz-desktop start (backgrounded)

[manual]    → cpz-desktop start | stop | status
```

- udev rule (`/etc/udev/rules.d/99-cpz-hdmi.rules`):

```
ACTION=="change", SUBSYSTEM=="drm", DEVPATH=="*/card0-HDMI-A-1", \
  RUN+="/usr/sbin/cpz-hdmi-event"
```

  `RUN+` must return instantly — the script itself decides and spawns.
- `hdmi_force_hotplug` stays **OFF** so the connector state is a *real*
  signal (this also keeps fbcon honest — no phantom displays).
- Default `/etc/cpz/hdmi-mode` = `ask` (safe: user consent each time);
  `auto` is one edit away.

## 3. The two GPU profiles (the one thing we can't do at runtime)

`gpu_mem` is firmware-fixed at boot; there is no runtime re-sizing of the
VideoCore split. So the desktop has two flavors:

| Profile | gpu_mem | CMA | Renderer | Good for |
|---|---|---|---|---|
| **console** (default) | 32 MB | 64 MB | **llvmpipe** (CPU GL) | terminals, browsers-lite, file managers — plenty for a quad A53 at 1080p |
| **desktop** (opt-in boot) | 96 MB | 128 MB | vc4 GLES + VideoCore H.264 1080p30 decode | video playback, GL apps |

`cpz-desktop-profile desktop|console` edits `config.txt`/`cmdline.txt` and
**requires one reboot** — that's the honest price of the platform, and the
reason the default profile must stay capable: a hotplug session on the
console profile still gives a fully usable llvmpipe desktop in ≤10 s.
Choosing the desktop profile is for a "dock it for the evening" session.

## 4. The session stack

| Layer | Choice | Why |
|---|---|---|
| Seat management | **seatd** | works without systemd-logind; tiny daemon |
| Compositor | **sway** (config-known output control) | `output <LCD> disable` keeps the session HDMI-only; fallback `labwc`/`cage` if RAM says so |
| Terminal | **foot** | Wayland-native, light, excellent on small stacks |
| GL | mesa, **llvmpipe** default / vc4 Gallium in desktop profile | mesa subpackage resolved in S08 |
| Audio | ALSA only — **no pipewire/pulse** | two cards: es8389 (device) / vc4-hdmi (desktop); `/etc/asound.conf` symlink switched by `cpz-desktop` |
| Input | USB keyboard/mouse via the host port | internal keyboard's xkb map = optional polish (the desktop lives on HDMI where real keyboards exist) |

Session mechanics (`cpz-desktop start`, run as user `cpz`, member of
`seat`/`video`/`input`):

1. `rc-service seatd start` (oneshot; nothing at boot, D-list in docs/03).
2. `seatd-launch sway -c /etc/cpz/sway.config` as user `cpz` from the tty of
   whoever ran the command — no login manager.
3. `sway.config` essentials:

```
# keep the session on HDMI only — name confirmed via swaymsg -t get_outputs
output <LCD-connector> disable
output HDMI-A-1 mode 1920x1080@60Hz

exec foot
# status bar: a tiny waybar or a bare `wayland-info` clock — measured in S08
```

4. `cpz-desktop stop` kills the session (sway exits, seatd stops) and
   prints `free -m` before/after — the RAM-reclaim proof the gate requires.

## 5. What runs where (RAM accounting, measured in S08)

- Console-profile hotplug session: sway + foot + llvmpipe ≈ 80–150 MB —
  fits comfortably in the ~300 MB headroom *with all console services still
  running*. No service-shedding gymnastics expected; if measurements say
  otherwise: zram (S09) first, `labwc` second.
- Desktop-profile session: same userland + vc4 allocations inside the 96 MB
  gpu_mem + 128 MB CMA.
- HDMI audio: `cpz-desktop` swaps `/etc/asound.conf` → default card
  `vc4-hdmi`; stops → back to es8389.

## 6. Acceptance (mirror of Stage 08 gate)

- [ ] Cold boot: `pgrep -c sway` = 0; `free -m` ≤ 60 MB used
- [ ] `cpz-desktop start` → usable HDMI session ≤ 10 s, LCD console live
- [ ] Hotplug with `auto`: session starts unattended; with `ask`: notice
      appears on LCD only
- [ ] `cpz-desktop stop` → RAM returns to ≤ +10 MB of pre-start, LCD console
      intact
- [ ] 1080p output stable; desktop profile: H.264 1080p30 decode works
- [ ] Repeat start/stop 10× — no leaked processes/RAM (udev rule + seatd
      cleanliness)
