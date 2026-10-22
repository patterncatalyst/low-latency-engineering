# r01-lab

Lab evidence for S12/S13, captured 2026-10-22 on `lowlat-target` rebuilt from
scratch with the scripts (destroy, provision, snapshot `lab-ready`,
`SNAPSHOT=lab-ready-rt install-rt-kernel.sh`). All output is from the guest
(label: VM) except `snapshots.txt` and `domains.txt` (libvirt on the host,
read-only).

- `check-prereqs-vm.txt`: `scripts/check-prereqs.sh --vm`, 9 PASS.
- `guest-kernel.txt`: `uname -rv` shows PREEMPT_RT; the running kernel's config
  has `CONFIG_PREEMPT_RT=y`.
- `guest-ptp.txt`: `/dev/ptp0` is "KVM virtual PTP", loaded at boot by
  `/etc/modules-load.d/ptp_kvm.conf` (cloud-init).
- `guest-phc2sys.txt`: 20 s of `phc2sys -s /dev/ptp0 -c CLOCK_REALTIME -O 0 -m`.
  The first two samples step the guest clock (state s0/s1, about 5.4 s apart
  because the freshly booted guest clock was not yet synced); from s2 on, the
  offset to the host clock stays within a few ns. A lock check, not a
  measurement.
- `snapshots.txt`: `lab-ready` and `lab-ready-rt`.
- `domains.txt`: the other labs' domains (`ebpf-*`, `systems-*`) shut off and
  untouched.
