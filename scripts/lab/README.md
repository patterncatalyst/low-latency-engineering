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
sshd on vsock by itself. The destination is `fedora@qemu:system/<vm>`, with a
lab-only known_hosts file under `$LAB_CACHE`. No host port is opened.

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

Real-time and time: `realtime-tests` (cyclictest; not Fedora's unrelated `rt-tests`), `linuxptp`, `chrony`, `tuned` with
`tuned-profiles-cpu-partitioning`, `realtime-setup`. Profiling: `perf`,
`kernel-tools`, `numactl`. Toolchains: `gcc-c++`, `clang`, `cmake`,
`ninja-build`, `java-25-openjdk-devel`, `maven`, `python3`, `uv`, plus `jq`,
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

The script never installs the RPMs. Installing them is a guest-only step.
