# Proxmox Kernel Maintenance

How kernels are managed on `pve-01/02/03`, why `apt autoremove` never prunes them, and the
procedure for doing it by hand.

## How kernels work on these hosts

Two facts shape everything below, and neither matches the Proxmox documentation's default
assumptions:

- **`proxmox-boot-tool` is not in use.** `/etc/kernel/proxmox-boot-uuids` does not exist. The ESP is
  mounted through `fstab` and kernels install via stock Debian machinery and GRUB. Every recipe
  built on `proxmox-boot-tool kernel list` / `pin` / `clean` is inapplicable here — it will report
  nothing and quietly do nothing.
- **`/boot` is not a separate filesystem.** Kernels live under `/` on `pve-root` (94 GiB, about 10%
  used). The usual "`/boot` filled up and now `apt` is wedged" failure cannot occur here, which is
  why this is a tidiness task and not an operational one.

The hosts have **no IPMI or IKVM**. A host that will not boot needs a keyboard and monitor attached
in person. That is the reason for the caution below and for keeping a fallback kernel.

## Why `autoremove` does not prune kernels

`ansible-update-linux` runs `apt autoremove` weekly across every host including these, and it has
never removed an old kernel. Two independent reasons:

1. **The versioned packages are marked manually installed.** `apt-mark showmanual` lists them, and
   `autoremove` only ever considers automatically-installed packages. They are manual because the
   PVE upgrade installed them by name rather than pulling them as dependencies of a metapackage.
2. **The kernel safety net is missing.** On Debian, `/etc/kernel/postinst.d/apt-auto-removal`
   generates `/etc/apt/apt.conf.d/01autoremove-kernels`, listing the running and newest kernels as
   `NeverAutoRemove`. **That file does not exist on any of these hosts** — Proxmox installs kernels
   through `proxmox-kernel-helper`, which does not trigger the Debian hook.

Reason 1 alone would make `apt-mark auto` the obvious fix. Reason 2 is why that would be a mistake:
without the protection list, an `autoremove` on auto-marked kernels has nothing stopping it removing
the one currently running. On hardware with no out-of-band access, that is the one failure with no
remote recovery.

**So kernel pruning stays manual, and deliberately so.** It is properly an act performed *after*
confirming a new kernel boots — not something a weekly job should attempt. Accumulation is about two
stale kernels per major upgrade, roughly 600 MB each, against 80 GiB free.

## Target state

Each host carries the **running kernel plus exactly one fallback**:

| | Version | Role |
|---|---|---|
| Running | `7.0.14-12-pve` | current |
| Fallback | `6.8.12-42-pve` | last known-good from PVE 8 |

The `proxmox-kernel-6.8` metapackage is kept deliberately — it is what pins the fallback in place.
Removing it would let a later `autoremove` take `6.8.12-42-pve-signed` with it, leaving no fallback
at all.

## Procedure

### 1. Survey before touching anything

```bash
for h in 21 22 23; do
  echo "═══ .$h ═══"
  ssh -n root@${LAN_PREFIX}.$h '
    uname -r
    dpkg -l "proxmox-kernel-*" | awk "/^ii/ {print \$2, \$3}"
    ls -1 /boot/vmlinuz-*
    df -h / | tail -1'
done
```

`ssh -n` is load-bearing inside the loop — without it the first connection consumes stdin and the
remaining hosts are silently skipped.

### 2. Dry run

Identify the versions to drop: everything except the running kernel and the chosen fallback. Then,
per host:

```bash
apt-get purge --dry-run proxmox-kernel-<VERSION>-pve-signed
```

Expect exactly the packages you named and nothing else. **Stop if the output mentions
`proxmox-kernel-6.8`, any `7.0` package, or `pve-manager`** — that means a dependency is holding
something you did not intend to touch.

### 3. Purge, and verify the boot menu

```bash
apt-get purge -y proxmox-kernel-<VERSION>-pve-signed
ls -1 /boot/vmlinuz-*
grep -oE "vmlinuz-[0-9][^ ]*" /boot/grub/grub.cfg | sort -u
uname -r
```

The purge triggers `update-grub` through the kernel `postrm` hook, so the menu regenerates on its
own. **Confirm the GRUB menu lists both remaining kernels before any subsequent reboot.** A menu
that lost an entry is recoverable while the host is still up and effectively not recoverable once it
is not.

No reboot is required. Purging a kernel that is not running does not affect the running system.

## History

- **2026-08-19** — the PVE 8 → 9 upgrade left 18 `6.8.12-*` packages. `apt autoremove` took the two
  it considered safe (1,156 MB per host); a manual pass in the upgrade's phase 3 removed the rest
  bar two.
- **2026-08-20** — purged `proxmox-kernel-6.8.12-9-pve-signed` from all three, reaching the target
  state above. About 600 MB per host; root usage went from 9.2 GiB to 8.6 GiB.

## References

- [Proxmox VE 8 to 9 upgrade](https://pve.proxmox.com/wiki/Upgrade_from_8_to_9)
- [Proxmox Monitoring](../infrastructure/proxmox-monitoring.md) — where host disk alerts are defined
