# CPZ-Alpine v0.21.11 — restore before the launcher, verify the flash

Two structural fixes for "basic settings are NOT preserved after re-flash":

## What's new

- **`cpz-restore` is now a boot-runlevel service, not a `local.d` script.**
  `local.d` runs **after** every default service — after `applaunch` had
  already loaded the default settings (brightness/dark-time/volume), after
  `dropbear` had already loaded its host keys, and after NetworkManager had
  already scanned for connection profiles. That is why the card booted with
  80% brightness / 30s dark-time / 90% volume, why the SSH host key changed,
  and why Wi-Fi would not auto-connect even when `/cfg` held the right
  archive. The restore now runs in the `boot` runlevel with
  `before applaunch networkmanager dropbear`, so the saved settings, host
  keys and Wi-Fi profiles are on disk before any of them start.
- **The flasher's snapshot write-back now verifies itself.** It retries the
  read-write mount up to 5 times, rewrites the backed-up files, syncs,
  compares the rewritten `save.tar.gz` byte count against the backup, and
  **aborts with an error** (leaving the pre-flash copy in
  `cpz-cfg-backup-*`) if the mount fails or the sizes differ. The v0.21.10
  failure restored a 24,763-byte archive while the backup held 31,494 bytes
  with `{"brightness": 50, "dark_time": 300, "volume": 50}`, the Wi-Fi PSK,
  the host keys and Tailscale — exactly your reported symptoms.
- The watcher now also watches `~/.config` so a Settings change triggers an
  immediate snapshot instead of waiting for the next 5-minute tick.

## What the user should see on the next flash

```
== existing CPZDATA detected — protecting it ==
   /cfg snapshot backed up to .../cpz-cfg-backup-...
== restoring the pre-flash /cfg snapshot ==
   snapshot rewritten: N bytes (backup: N bytes)
done. Boot the card: ...
```

If anything else appears (an `ERROR` line, or a size mismatch), **stop** —
the pre-flash copy is safe in the `cpz-cfg-backup-*` directory, and the card
has not been left to boot an older snapshot.

## Untested / needs a hardware pass

- The boot-runlevel restore has not been through a real flash+boot; it is
  the same script as before, just started earlier (OpenRC `boot` before
  `default`).
- The NTP toggle and manual-time UI are unchanged from v0.21.10 and have not
  been clicked on hardware.
