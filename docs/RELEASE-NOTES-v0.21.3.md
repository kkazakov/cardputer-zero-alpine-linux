# CPZ-Alpine v0.21.3 — optional Tailscale app

This release adds an on/off **Tailscale** card to the launcher. Tailscale
stays an optional, user-installed package: the card is compiled in but
hidden until the daemon is installed **and** the node has been logged in.
The image itself is unchanged otherwise — same Alpine 3.24 aarch64/musl
base, same launcher apps, same `/cfg` persistence.

## What's new

- **Launcher: Tailscale on/off card.** It sits next to HDMI in the home
  carousel and toggles the Alpine `tailscale` service:
  - **ON** adds `tailscale` to the default runlevel and starts the daemon.
  - **OFF** removes the runlevel link first, then stops the daemon, so the
    tunnel does not briefly reconnect during each boot.
  - The switch polls the real daemon (`pidof tailscaled`), so it never lies
    after a manual `rc-service tailscale start/stop`.
  - ENTER toggles, ESC returns home; the page layout matches the HDMI one.
- **Conditional visibility.** The entry carries an availability predicate
  (`AppDescriptor::available`) that calls
  `/usr/local/bin/cpz-tailscale available`. The card (and its
  Settings → Launcher toggle) only appears when
  `/usr/sbin/tailscaled` + `/etc/init.d/tailscale` exist **and**
  `/var/lib/tailscale/tailscaled.state` contains a non-empty `_profiles`
  (i.e. `tailscale up` completed). The home screen re-polls every 20 s, so
  the card appears after an `apk add` + login without restarting the
  launcher — important on the first boot after a reflash, when
  `cpz-wifi.start` reinstalls packages in the background.
- **State survives reboots.** The preference is stored in
  `/var/lib/applaunch/tailscale` (`1`/`0`) and re-applied by
  `/etc/local.d/cpz-tailscale-boot.start` (which waits, bounded, for the
  package to reappear after a reflash).
- **Tailscale login survives reflashes.** `/var/lib/tailscale` (node key,
  login profiles, prefs) is now part of `cpz-save` and is restored through
  pass A by `cpz-restore.start`. The package itself is still not in the
  image; `/etc/apk/world` + `/cfg/pkglist.txt` reinstall it at boot.
- **Manual control helper** `/usr/local/bin/cpz-tailscale`:
  `available`, `state`, `on`/`off`, `apply on|off`, `boot`.
- **README**: a full "Tailscale (optional, on demand)" section with the
  manual `apk add tailscale tailscale-openrc`, `rc-update add tailscale
  default`, `rc-service tailscale start`, `tailscale up` steps, the
  launcher flow, manual CLI control, persistence notes, the
  remote-access warning, and a troubleshooting table.
- This release also contains the v0.21.2 password persistence work
  (root/cpz password changes survive a reflash via `/cfg/shadow-users`).

## Known issues

- **Tailscale is not installed in the image.** Until you run
  `apk add tailscale tailscale-openrc` and `tailscale up`, the card is
  intentionally absent. That is the documented behaviour, not a bug.
- **Turning the tunnel OFF on a tailnet-only device cuts remote access.**
  The device disappears from the tailnet and SSH over `tailscale0` dies
  with it. Use the 14-pin serial console, the LAN address, or schedule a
  re-enable (`nohup sh -c 'sleep 120; cpz-tailscale apply on' &`) before
  testing OFF remotely.
- **The service is `tailscale`, not `tailscaled`.** `rc-service tailscaled`
  reports "does not exist" even while the daemon runs. The process is
  `tailscaled`; only the OpenRC unit is `tailscale`.
- **`pgrep -x tailscaled` is useless on this image's busybox** (it applies
  `-x` to argv[0], which is `/usr/sbin/tailscaled`). The helper and the
  page use `pidof tailscaled`; keep that in mind for scripts.
- The first boot after a reflash can take up to ~20 s after the apk
  reinstall finishes before the card appears (availability poll period).
  If the launcher was already running before the package existed, it
  appears without a restart; if you are impatient, `rc-service applaunch
  restart`.
- No public automation RPC is compiled in, so the release's UI tests were
  done over SSH with framebuffer captures, not with synthetic key events.
- Windows and macOS flashers are unchanged from v0.21.2 and still have the
  documented "no `/cfg` on a clean install" limitation.

## Untested / needs a hardware pass

- **OFF across a real reboot was verified by simulation, not by rebooting
  into OFF.** Doing that on a tailnet-only unit would strand it (the
  device would not come back until serial/LAN access). What was tested on
  hardware: `cpz-tailscale boot` with preference `0` stops the daemon,
  keeps the runlevel link removed, and leaves the preference at `0`; and
  a real reboot with preference `1` comes back with the tunnel up.
- **Full reflash cycle with Tailscale installed.** The `/var/lib/tailscale`
  save/restore path was exercised on a live device (`cpz-save` → archive
  contains the state → reboot → daemon up, node not re-authenticated), but
  the actual "write the new image, reinstall the apk in the background,
  card appears" flow has not been run end to end on a card.
- **Physical ENTER toggle on the Tailscale page.** The page was rendered
  and its poll-driven ON/OFF states were captured; toggles were exercised
  through `cpz-tailscale apply`, which is the same code path the switch
  calls. The HDMI page's ENTER handling is unchanged and field-proven.
- `tailscale up --ssh`, `--accept-routes`, `--advertise-exit-node` and
  exit-node use are documented but not exercised on this hardware.
- The device used for the pass is a tailnet-only unit (Wi-Fi LAN not
  reachable from the build environment); a unit with a serial or LAN
  rescue path should still get the OFF-reboot test.
