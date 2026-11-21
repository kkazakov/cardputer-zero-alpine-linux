# CPZ-Alpine v0.21.8 — event-driven persistence watcher

## What's new

v0.21.7 closed the "card pulled while running loses the latest save" gap
by polling the config paths every 5 s. That worked, but every tick forked a
`stat` binary per watched file plus a `find` and an `md5sum` — ~20–40
process spawns every five seconds, 24/7, for a save it almost never had to
make. It was CPU busywork (the `stat` calls only touch inode metadata that
is already in the page cache, so it was **not** wearing out the SD card),
but on this class of device that kind of idle noise is still real overhead.

- **Event-driven saves.** `cpz-state-watch` now drives busybox `inotifyd`
  over the config files (modify/write/close/metadata → save) **and** over
  their five parent directories (subfile create/move/delete → save). A
  password change, a joined Wi-Fi profile, a Tailscale toggle or an SSH key
  now triggers `cpz-save` the instant it lands, with no timer.
- **60 s poll fallback, not 5 s polling.** A scheduler still runs a
  signature over the watched paths every 60 s, but only as the safety net
  for the cases inotify cannot report as a content change: an event-queue
  overflow (`o`), a lost watch after an atomic rename (`x` — e.g.
  `shadow.new` → `/etc/shadow` replaces the inode), or a backing-fs
  unmount (`u`). The fallback uses `find -exec stat | md5sum` (busybox
  `find` has no `-printf`), so idle CPU is a handful of metadata reads a
  minute instead of 20–40 process spawns every five seconds.
- **The inotify callback is a real executable**
  (`/usr/local/bin/cpz-state-watch-handler`). `inotifyd` execs `PROG` per
  event and cannot call a shell function defined in the watcher script;
  the handler ignores tailscaled's churning `derpmap.cached.json` and
  debounces the `w`+`0` pair of a single write.
- **Directory watches catch atomic renames.** A plain file watch never sees
  `mv shadow.new /etc/shadow` — the old inode just dies with `x`. Watching
  the parent directory for `e/y/n/m/d` subfile events is what makes the
  rename case (used by `cpz-restore`'s own shadow merge, passwd tools, and
  NM keyfile writes) trigger a save reliably.
- **Start hook spawns three detached instances** (`save`, `dir`, `fallback`)
  and reaps any previous generation with `pkill` so an `rc-service local
  restart` never stacks watchers.
- **The shutdown save waits for an in-flight one.** `cpz-save --wait`
  retries the lock for ~10 s, so `cpz-save.stop` no longer loses the final
  snapshot just because the watcher/cron was writing at poweroff.
- **`cpz-restore` waits for the partition and logs before it can fail.**
  It waits up to 15 s for `/dev/mmcblk0p3`, retries the mount five times,
  and writes `/var/log/cpz-restore.log` on the rootfs (as well as
  `/cfg/cpz-restore.log`) so a boot that cannot mount `/cfg` is
  diagnosable instead of silent.
- **`flash-cpz.sh` cannot silently erase `/cfg` any more.** Before
  writing, it repairs a dirty ext4, copies `save.tar.gz`,
  `save.tar.gz.prev`, `shadow-users` and `pkglist.txt` into
  `cpz-cfg-backup-<time>/` in the current directory, and aborts rather
  than formatting an existing ext4. `--format` is the explicit opt-in to
  erase it.

The `.prev` archive fallback and `/cfg/cpz-restore.log` trace from v0.21.7
are unchanged.

## Known issues

- The watcher still does **not** cover `/home/cpz` media (photos/video);
  that remains on the 5-minute cron + shutdown snapshot, so a card pulled
  mid-camera-session can lose recent media.
- A card pulled **during** a `cpz-save` write can still leave the archive
  incomplete; the `.prev` generation (or the 5-minute cron) is the
  fallback. This is a write-durability question (fsync of the archive and
  its directory entry), not a watcher-cadence question, and is not addressed
  here.
- `/cfg` must be mounted. If the flasher ever leaves p3 unformatted, the
  watcher cannot save anything; check `mountpoint /cfg`.

## Untested / needs a hardware pass

- The inotify chain was validated in the builder container: a real
  `inotifyd` event on `/etc/hosts` and a new NM profile each invoked the
  handler and the stub `cpz-save`, and the start hook spawned exactly the
  three intended processes (two `inotifyd`, one fallback). It has **not**
  been on the live device yet; the device is aarch64 and the build/verify
  path runs in a container.
- The boot-time start hook has not been through a full reboot on this image.
  It is the same `local.d` mechanism the other hooks use; the container test
  only proves the script starts the trio when invoked.
- Verify on hardware: flash v0.21.8, then (1) `touch /etc/hosts` and confirm
  `/cfg/save.tar.gz` mtime moves within ~1 s (event save, not the fallback),
  (2) `mv /etc/shadow /tmp && mv /tmp/shadow.new /etc/shadow` to confirm the
  rename is caught, (3) watch `ps` to confirm the idle watcher spawns no
  per-tick processes, and (4) confirm only the expected three instances are
  running after an `rc-service local restart`.
