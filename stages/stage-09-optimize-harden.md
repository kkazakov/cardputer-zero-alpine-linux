# Stage 09 — Optimize & harden (meet the budgets)

> Phase IV · depends on: Stages 03–08 complete (G2+G3) · effort: 2–4 h · status: **not started**

## Goal

Turn "it works" into "it meets the numbers": idle ≤ 60 MB with radios on,
boot ≤ 12 s, image ≤ 1 GB — *measured*, not estimated. Plus the pocket-
device hardening: clean shutdowns, SD-corruption resilience, locked-down
SSH, honest logging.

## Steps

### 1. Measure first, tune second

```sh
# boot time: dmesg timestamps + stopwatch to LCD prompt (docs/06 §5)
free -m                       # after 2 min idle, radios on
rc-status --all               # the pruning checklist
for p in $(ps -eo pid --no-headers); do grep -H VmRSS /proc/$p/status 2>/dev/null; done \
  | sort -t: -k2 -rn | head -20    # the actual RAM hogs, ranked
```

Fill PLAN §6 tables with **measured** values (replacing targets).

### 2. Service pruning

With `rc-status --all` open, disable everything not in docs/03 §6's
inventory. Expected victims: leftover `setup-alpine` services, any logging
that isn't the busybox ring, anything network-adjacent we don't use.

- [ ] Post-prune: full cold-boot regression (docs/06 §1 smoke) still passes

### 3. Boot time trim

- [ ] mkinitfs audit: features/modules trimmed to exactly Stage 03's list
      (initramfs size check: `ls -lh /boot/initramfs-*`)
- [ ] OpenRC: parallel startup (`rc_parallel=YES` in `/etc/rc.conf`) —
      measure; keep only if it helps and nothing races (wpa/networking
      order from docs/04 §6)
- [ ] `quiet` restored to cmdline only *after* everything is stable
- [ ] Re-measure: target ≤ 12 s (stretch 8 s)

### 4. Power polish (R9 follow-through)

- [ ] 30-min idle battery benchmark vs Stage 06's baseline → record the
      delta (powersave + pruning + blanking should show it)
- [ ] Optional `arm_freq` underclock decision recorded either way

### 5. Storage & corruption resilience (R8)

- [ ] `fsck` on boot for the ext4 root (default, verify it runs)
- [ ] `noatime` on root; logs to the busybox ring (no SD writes)
- [ ] **Optional ro-root overlay** (decide by actual power-loss incidents,
      not fear): root mounted read-only, `/var`/`/etc` writable overlays in
      tmpfs, config writes go through a small `cpz-save` helper. Only adopt
      if it doesn't fight apk — otherwise ext4+fsck+fast-shutdown stands
- [ ] zram decision: enable (128 MB) if S08's session measurements want it;
      record RAM/swap cost

### 6. Hardening

```sh
# dropbear: key-only, no root login
#   /etc/ssh/sshd_config equivalent for dropbear:
#   dropbear flags in /etc/conf.d/dropbear: "-w -s"  (no root, no password)
# (keep one console+serial access path tested before locking anything)
doas apk add doas   # confirm; wheel-only permit line already from S02
```

- [ ] SSH: pubkey-only, root login refused, `cpz` via doas — and **verify
      you can still get in** (serial console = the safety net)
- [ ] sysctl minimal pass: no listening services beyond dropbear +
      anything you deliberately run (`netstat -tlnp` as the checklist)
- [ ] apk world audit: no compilers/interpreters in the base image
      (docs/03 §7 rule)

### 7. Final budgets & sign-off

- [ ] All PLAN §6 tables now carry measured numbers
- [ ] docs/06 §1 smoke + §3 full regression + §4 on-demand regression —
      all green
- [ ] The "before" column (Stage 02 baseline) vs "after" column written
      into PLAN §6 — the bragging-rights table

## Files produced

Measured budget tables in PLAN §6 · pruned service inventory · hardened
configs in `rootfs-overlay/` (feeding Stage 10's build)

## Acceptance gate

- [ ] idle ≤ 60 MB radios-on; boot ≤ 12 s; image ≤ 1 GB — **measured**
- [ ] Battery benchmark recorded (baseline vs tuned)
- [ ] SSH hardened and *still accessible*; serial console proven as rescue
- [ ] Full regression green after every prune step (no victory-by-accident)

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| Locked out by hardening | serial console from the 14-pin bus is the permanent rescue path — tested before each lock |
| ro-root fights apk | skip ro-root (it's optional); ext4 + fsck + fast shutdown is the committed baseline |
| Parallel OpenRC races | revert `rc_parallel` — 12 s is achievable serially on this hardware |
