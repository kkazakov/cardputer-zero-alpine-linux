# CPZ-Alpine v0.21.4 — Tailscale OFF now survives a reboot

Fixes one bug in v0.21.3: after switching Tailscale **off** in the
launcher and rebooting, the tunnel came back up. The launcher state
directory was restored from `/cfg` on every boot, rolling the fresh
preference back to the last hourly snapshot.

The image is otherwise identical to v0.21.3 (same Alpine 3.24
aarch64/musl base, same apps, same `/cfg` persistence).

## What's new

- **`/var/lib/applaunch` is now treated as live state on a normal boot.**
  `cpz-restore.start` skips restoring that directory when it is already
  populated, so the running launcher's files win over the hourly snapshot.
  This fixes all launcher state, not just Tailscale:
  - Tailscale switched **OFF** stays off after a reboot.
  - The HDMI desktop preference behaves the same way.
  - Launcher settings changed after the last `cpz-save` are no longer
    reverted by a reboot.
- **Fresh flashes still restore the saved launcher state.** The image
  ships an **empty** `/var/lib/applaunch`, so the archive still populates
  it after a reflash — the empty directory is the reliable "new rootfs"
  marker.
- No launcher binary change: the v0.21.3 launcher, helper and boot hook
  are unchanged. Only the restore script differs (plus the version bump).

## Known issues

- **A card upgraded from v0.21.3 needs the new image** — the fix lives in
  `/etc/local.d/cpz-restore.start`, not in the launcher binary. Copying a
  launcher binary alone will not fix the reboot behaviour.
- The first boot of a **fresh** card still restores `/var/lib/applaunch`
  from `/cfg` (that is the intended reflash path); only subsequent boots
  keep the live state. If a saved preference is stale at flash time, that
  one boot uses it; toggle the switch once after flashing if you need to
  be certain.
- **Turning Tailscale OFF on a tailnet-only device cuts remote access.**
  Use the 14-pin serial console, the LAN address, or schedule a re-enable
  (`nohup sh -c 'sleep 120; cpz-tailscale apply on' &`) before testing
  remotely.
- Everything else from v0.21.3 still applies: Tailscale is an optional
  on-device package (`apk add tailscale tailscale-openrc` +
  `tailscale up`), the service is named `tailscale` (not `tailscaled`),
  and busybox `pgrep -x tailscaled` does not match (use `pidof`).

## Untested / needs a hardware pass

- **A real reboot with Tailscale OFF on this unit was not performed**:
  the device is reachable only over its tailnet address, so an OFF reboot
  would strand it. The fix was verified by running the exact boot path on
  the device: live preference `0`, an archive that still held `1`,
  `cpz-restore.start` kept `0`, and `cpz-tailscale boot` left the daemon
  stopped with the runlevel link absent. A unit with serial or LAN access
  should still get the real OFF-reboot test.
- A **full reflash** of the release image onto the card has not been
  done here; the image verification pass is clean and the restore script
  was exercised on the live rootfs.
- The rest of the v0.21.3 Tailscale matrix is unchanged: `tailscale up`
  variants (`--ssh`, `--accept-routes`, exit node) and a physical ENTER
  toggle on the page were not re-run for this patch.
