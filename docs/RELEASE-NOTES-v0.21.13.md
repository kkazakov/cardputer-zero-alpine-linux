# CPZ-Alpine v0.21.13 — Date & Time actually works

## What's new

- The Date & Time page's privileged writes (`NtpSet`, `TimeSet`) went
  through the launcher's sudo coordinator, which runs `sudo -S` with a
  password prompt. On the Alpine image that prompt flow never completes
  (cpz has NOPASSWD sudo and the fork has no prompt dialog), so the
  network-time toggle and the manual time commit silently did nothing —
  `/cfg/ntp` was never written and `ntpd` never started.
- They now run directly through the process API with `sudo -n`, the same
  path the HDMI/Tailscale pages use:
  - NTP on → `sudo -n /usr/local/bin/cpz-ntp set 1` (writes `/cfg/ntp`,
    starts busybox `ntpd` against `pool.ntp.org`)
  - NTP off → `cpz-ntp set 0`
  - Manual time → `sudo -n /bin/sh -c "date -s 'YYYY-MM-DD HH:MM:SS'; hwclock -w"`
- `NtpGet` already falls back to `/cfg/ntp` (disabled when absent), so the
  toggle shows a real state after the first successful set.

## Untested / needs a hardware pass

- Compiled only; not yet clicked on the device. Verify: toggle Network
  time ON → `sudo cat /cfg/ntp` should read `1` and `pidof ntpd` should be
  non-empty; set a manual time → `date` changes and `hwclock -r` matches.
