# Low-latency lab: KVM/libvirt guest

A disposable Fedora 44 KVM guest for the real-time, PTP, tuned and container
work in this book. Adapted from the `lgtm-systems-programming` lab. Build and
edit on the host; run anything privileged (kernel parameters, `isolcpus`,
`tuned`, `cyclictest`, PTP) in the guest, snapshot it, and revert in seconds.

Everything keys off `LAB_PREFIX` (default `lowlat`), so the guest is
`lowlat-target`. Settings live in one file, `lab.env`; every value can be
overridden from the environment.

## Name guard

Other projects' guests (`ebpf-*`, `systems-*`) share this libvirt instance.
Every script checks each domain name against `LAB_GUARD_PREFIX` (`lowlat-`)
**before the first `virsh` call** and exits non-zero with `refusing '<name>'`
for anything else. A wrong `LAB_PREFIX`, a stray `TARGET_VM`, or a typo cannot
reach another project's VM.

## Networking: passt, ssh over vsock

The lab changes nothing on the host. Each guest uses QEMU's passt backend
(`<interface type='user'><backend type='passt'/>`): the guest's outbound traffic
leaves through ordinary unprivileged sockets that passt opens on the host, so
there is no bridge, no NAT, no forwarding and no firewall rule, and Docker's
firewall rules cannot interfere. Guests have no host-reachable IP address. ssh
goes over AF_VSOCK (`--vsock cid.auto=yes`) through libvirt's ssh proxy
(`/etc/ssh/ssh_config.d/30-libvirt-ssh-proxy.conf`); the guest's systemd starts
sshd on vsock by itself. `lib.sh` writes a lab-only ssh config,
`$LAB_CACHE/ssh_config`, that gives each `lowlat-*` guest a plain alias (its
domain name) routed through the proxy, with a lab-only known_hosts file. ssh, scp
and rsync all use it: `ssh -F ~/.cache/lowlat-lab/ssh_config lowlat-target`, or
just `lab-ssh.sh`. (The proxy's own names, `qemu:system/<vm>`, contain a colon
that scp and rsync misparse.) No host port is opened.

The cost: guests cannot reach each other. Every r01 measurement runs inside one
guest. A two-guest path (PTP, network chapters) needs its own design when it is
needed, never a change to the shared host's firewall.

## Base image (S0 placeholder)

`lab.env` holds `BASE_URL`, `BASE_IMG` and `BASE_SHA256`. `BASE_IMG` and
`BASE_SHA256` are `TODO(S0)` placeholders until the dependency survey fills in
the Fedora 44 Cloud Base filename and checksum. `provision-vm.sh` refuses to run
while they are unset and verifies the sha256 of the cached image before every use.

## Host prerequisites (once)

```bash
sudo dnf install -y virt-install qemu-img cloud-utils libvirt libvirt-ssh-proxy passt passt-selinux rsync
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER"      # re-login, or wrap commands in: sg libvirt -c '...'
[ -f ~/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
```

## Lifecycle

```bash
scripts/lab/provision-vm.sh lowlat-target   # download+verify image, overlay disk, cloud-init, boot
scripts/lab/lab-ssh.sh lowlat-target cat /var/log/lab-ready   # expect: lab-ready: ok  (wait for cloud-init)
scripts/lab/snapshot-vm.sh lowlat-target    # snapshot 'lab-ready': your revert point
scripts/lab/lab-up.sh                       # start, wait for ssh over vsock
scripts/lab/lab-status.sh                   # state, ssh destination, readiness, snapshots
scripts/lab/lab-ssh.sh [vm [command...]]   # ssh as fedora (passwordless sudo)
scripts/lab/deploy-to-vm.sh                 # rsync examples/ and scripts/ into the guest
scripts/lab/revert-vm.sh lowlat-target [snapshot]   # undo a destructive run
scripts/lab/lab-down.sh                     # graceful shutdown; FORCE=1 to power off
scripts/lab/destroy-vm.sh lowlat-target     # tear down, disks included
```

`RENDER_ONLY=1 scripts/lab/provision-vm.sh lowlat-target` prints the rendered
cloud-init user-data and exits without touching libvirt.

Snapshot names: `lab-ready` (tooled baseline) is the default. Later
snapshots such as `lab-ready-rt` are passed as the second argument.

## Sizing

Defaults: 4 vCPU, 8192 MB RAM, 40 GB disk (`VCPUS`, `RAM_MB`, `DISK_GB`).

## Guest toolset

Real-time and time: `realtime-tests` (cyclictest; not Fedora's unrelated `rt-tests`), `linuxptp` (with the `ptp_kvm` module loaded at boot, giving `/dev/ptp0` "KVM virtual PTP"), `chrony`, `tuned` with
`tuned-profiles-cpu-partitioning`, `realtime-setup`. Profiling: `perf`,
`kernel-tools`, `numactl`. Toolchains: `gcc-c++`, `clang`, `cmake`,
`ninja-build`, `java-25-openjdk-devel` (Fedora's JDK stays installed but is not selected), the pinned Temurin JDK (below), `stress-ng`, `maven`, `python3`, `uv`, plus `jq`,
`git`, `rsync`. Containers: Docker Engine from Docker's Fedora repository
(`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`); the
guest user is in the `docker` group. No podman. The guest user `fedora` has
passwordless sudo and your `~/.ssh/id_ed25519.pub`.

## Optional peer

Set `LAB_PEER=1` to make `lab-up`, `lab-down` and `lab-status` also manage
`lowlat-peer` (provision it with `provision-vm.sh lowlat-peer`). Off by default.
With passt networking the peer cannot reach the target directly (see above).

## Measurement labelling

Numbers measured in the guest are labelled `vm` and are never compared with
bare-metal numbers. Record the guest profile (vCPUs, tuned profile, pinning,
isolation) with every result.

## Conventions

- One guest, serial runs: do not fan out parallel jobs against the same VM.
- Snapshot before destructive work, revert after; bring the lab down when done.
- Stop other clusters or VMs you are not using; this lab has priority on host CPU.

## PREEMPT_RT kernel (built in a container, installed only in the guest)

Fedora 44 ships no `kernel-rt`, and the stock kernel is built without
`CONFIG_PREEMPT_RT`. `build-rt-kernel.sh` rebuilds Fedora's own kernel SRPM
(`kernel-7.2.11-200.fc44`, pinned in `_plans/dependency-pins.md`) using the SRPM's own
realtime flavour (`--with realtime --with rtonly`, `kernel-x86_64-rt-fedora.config`)
plus the one-line fragment `kernel/preempt-rt.config` (DEBUG_PREEMPT off), merged
through the spec's `kernel-local` mechanism, under the release suffix `.lowlatrt` so the RPM names
never collide with stock kernels.

```bash
scripts/lab/build-rt-kernel.sh     # an hour or more; log: $LOWLAT_KERNEL_OUT/build.log
```

The build runs entirely in a throwaway `docker run --rm` container from the
digest-pinned `fedora:44` image. Nothing is installed on the host and no sudo is
used; the host only receives files. Output goes to `${LOWLAT_KERNEL_OUT:-$HOME/.cache/lowlat/kernel-rt}`:
`kernel-rt`, `kernel-rt-core`, `kernel-rt-modules`, `kernel-rt-modules-core` (and
`-extra` when produced) RPMs, `SHA256SUMS`, and `BUILDINFO` (NVR, fragment
sha256, image, date). The script fails unless the built config contains
`CONFIG_PREEMPT_RT=y`. Other overrides: `KERNEL_NVR`, `KERNEL_BUILDID`,
`FEDORA_IMAGE`.

The build script never installs the RPMs. Installing them is a guest-only step:

```bash
SNAPSHOT=lab-ready-rt scripts/lab/install-rt-kernel.sh lowlat-target
```

It copies the RPMs in over vsock, checks them against `SHA256SUMS`, installs them
next to the stock kernel of the same version (so stock vs RT runs differ only in
the preemption model), makes the RT entry the default by its BLS id, reboots, and
fails unless `uname -v` says `PREEMPT_RT`, the running kernel's config has
`CONFIG_PREEMPT_RT=y` and the Docker daemon is up. Mainline PREEMPT_RT has no
`/sys/kernel/realtime`. To boot stock instead, revert to `lab-ready` or set the
stock entry with `grub2-set-default` (grubby's `--set-default` silently does
nothing on Fedora Cloud's btrfs `/boot`).

Fedora's realtime config leaves out legacy iptables
(`CONFIG_NETFILTER_XTABLES_LEGACY`), so the guest uses `iptables-nft`
(cloud-init installs and selects it); with `iptables-legacy` Docker cannot start
on the RT kernel.

## Pinned JDK, isolation profile, vcpupin (r02)

**Temurin.** The guest's `java`/`javac` are the pinned Temurin tarball from `versions.env`
(`TEMURIN_VERSION`, `TEMURIN_URL`, `TEMURIN_SHA256`), unpacked to `/opt/temurin-<version>`, selected with
`alternatives` (so non-login ssh commands see it) and exported through `/etc/profile.d/temurin.sh`.
`scripts/lab/install-guest-tools.sh [vm]` installs it into an existing guest (host download into
`~/.cache/lowlat/downloads`, sha256-checked on the host and again in the guest, copied over vsock) together
with `stress-ng`; cloud-init does the same for a rebuilt guest (the guest downloads through passt and
checks the same sha256). `check-prereqs.sh --vm` fails unless the guest runs exactly that version.

**Guest isolation profile.** `guest-profiles/isolate-cpu3.conf` holds the kernel arguments
`isolcpus=3 nohz_full=3 rcu_nocbs=3` (documented in the file). `scripts/lab/apply-guest-profile.sh`
puts them on the PREEMPT_RT boot entry with `grubby --update-kernel=<index> --args`, reboots the guest and
verifies `/proc/cmdline` and `uname -v`. Only the RT entry changes; the stock entry is untouched.
grubby on Fedora Cloud's btrfs `/boot` spells kernel paths `/boot/boot/vmlinuz-...` and rejects both that and
the real path in `--update-kernel`, so the script addresses the entry by its grubby index; `--set-default` is
never used. It is idempotent (an entry that already matches is not rewritten or rebooted).
`apply-guest-profile.sh --remove` takes the arguments off again.

**vcpupin.** `scripts/lab/pin-vcpu.sh` pins vCPU 3 of `lowlat-target` to host CPU 13 with
`virsh vcpupin --config` (and `--live` when running) and prints `<cputune>` before and after;
`pin-vcpu.sh --remove` deletes the `<cputune>` block again. This is libvirt configuration of the lab
domain only. It is a pin, not an isolation: the host kernel may still schedule other work on CPU 13
and on its hyperthread sibling CPU 5, and nothing on the host is partitioned. Core 5 (CPUs 5 and 13)
had the fewest interrupts summed over both hyperthreads in `/proc/interrupts` on this host; check
`lscpu -e`, `thread_siblings_list` and `/proc/interrupts` before reusing the default elsewhere. Override with `PIN_HOST_CPU` / `PIN_VCPU`. The guest has 4 vCPUs (0-3), so guest CPU 3 is vCPU 3.

**Snapshot `lab-ready-iso`.** RT kernel + isolation profile + vcpupin + Temurin + `stress-ng`. It includes the
domain XML at that moment, so reverting to `lab-ready` or `lab-ready-rt` also restores the unpinned
domain, and reverting to `lab-ready-iso` restores the pin.

```bash
scripts/lab/revert-vm.sh lowlat-target lab-ready-iso   # isolated + pinned, tooled
scripts/lab/revert-vm.sh lowlat-target lab-ready-rt    # RT kernel, no isolation, no pin
scripts/lab/apply-guest-profile.sh --remove            # or undo in place
scripts/lab/pin-vcpu.sh --remove
```
