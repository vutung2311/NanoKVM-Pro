# NanoKVM-Pro Engineering Rules

## 1. Root Privileges & Execution
* On Linux systems, when running commands requiring administrative privileges, always use `pkexec` instead of `sudo`.
* Never execute destructive deletions (`sudo rm -rf` / `pkexec rm -rf`) without explicit user confirmation.

## 2. The "Build != Boot" Rule
* Successfully compiling or packaging (`dpkg-deb`) is not proof of a bootable system.
* Whenever adding or editing background services (`nanokvm`, `cua`, `kvmcomm`), verify that:
  1. `DEBIAN/postinst` executes `systemctl daemon-reload` and `systemctl enable <service>`.
  2. The service is linked in `/etc/systemd/system/multi-user.target.wants/`.
* When in doubt, run the automated verification runner:
  `pkexec python3 .agents/skills/nanokvm-rootfs-verification/scripts/verify_rootfs.py`

## 3. The `tmpfs /run` State Invariant
* In Linux, `/run` is mounted as an in-memory `tmpfs` upon system boot.
* Any directory required by a daemon under `/run` (such as `/run/sshd` for OpenSSH or `/run/kvmd` for PiKVM) must be defined in `/etc/tmpfiles.d/*.conf` or specified with `RuntimeDirectory=` in the systemd unit file.
* Never assume directories in `/run` persist across reboots.

## 4. UsrMerge Integrity
* On Ubuntu Jammy rootfs, `/bin`, `/sbin`, and `/lib` are symlinks pointing into `/usr/`.
* Any script, archive extraction, or rsync overlay operation must preserve these symlinks. Never replace them with concrete directories.

## 5. Kernel & Boot Partition Safety
* For AX630C eMMC, always flash alternate Slot B (`/dev/mmcblk0p13` for DTB, `/dev/mmcblk0p15` for kernel) when testing new kernels.
* Test boots should leverage RAM boot (`kexec`) or dual-slot switching (`fw_setenv bootsystem B`) to avoid bricking Slot A.
