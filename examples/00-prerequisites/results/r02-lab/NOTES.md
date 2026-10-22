# r02-lab

Lab evidence for S5, captured 2026-10-22 on `lowlat-target` (label: VM). Everything is from the
guest except `vcpupin.txt`, `snapshots.txt` and `domains.txt` (libvirt, read-only). The root
filesystem UUID is redacted in the command line.

- `guest-cmdline.txt`: `/proc/cmdline` carries `isolcpus=3 nohz_full=3 rcu_nocbs=3`
  (profile `scripts/lab/guest-profiles/isolate-cpu3.conf`, applied by `apply-guest-profile.sh`).
- `guest-kernel.txt`: still the PREEMPT_RT kernel; the boot entry's grubby args.
- `guest-java.txt`: Temurin 25.0.5+8 under `/opt/temurin-25.0.5`, `stress-ng` 0.22.01.
- `vcpupin.txt`: 4 vCPUs; vCPU 3 pinned to host CPU 13 (core 5, the core with the fewest
  interrupts over both hyperthreads; the first pin, CPU 15, shared core 7 with the second-busiest
  CPU and was moved the same day, and `lab-ready-iso` re-taken). `<cputune>` before: none; after:
  `<vcpupin vcpu='3' cpuset='13'/>`. A pin, not a host isolation.
- `snapshots.txt`: `lab-ready`, `lab-ready-rt`, `lab-ready-iso`.
- `check-prereqs-vm.txt`: `scripts/check-prereqs.sh --vm`, 13 PASS (incl. Temurin version,
  isolation and vcpupin state).
- `domains.txt`: `ebpf-*` and `systems-*` domains shut off, unchanged.

`scripts/profile.sh` was run on the host before and after: the diff is only `captured_at`, a pid
and the load averages.
