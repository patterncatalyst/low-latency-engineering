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

## Base image (S0 placeholder)

`lab.env` holds `BASE_URL`, `BASE_IMG` and `BASE_SHA256`. `BASE_IMG` and
`BASE_SHA256` are `TODO(S0)` placeholders until the dependency survey fills in
the Fedora 44 Cloud Base filename and checksum. `provision-vm.sh` refuses to run
while they are unset and verifies the sha256 of the cached image before every use.

## Host prerequisites (once)

```bash
sudo dnf install -y virt-install qemu-img cloud-utils libvirt rsync
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER"      # re-login, or wrap commands in: sg libvirt -c '...'
[ -f ~/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
```

## Lifecycle

```bash
scripts/lab/provision-vm.sh lowlat-target   # download+verify image, overlay disk, cloud-init, boot
scripts/lab/lab-ssh.sh lowlat-target cat /var/log/lab-ready   # expect: lab-ready: ok  (wait for cloud-init)
scripts/lab/snapshot-vm.sh lowlat-target    # snapshot 'lab-ready': your revert point
scripts/lab/lab-up.sh                       # start, wait for the lease, print the IP
scripts/lab/lab-status.sh                   # state, IP, readiness marker, snapshots
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

Real-time and time: `rt-tests`, `linuxptp`, `chrony`, `tuned` with
`tuned-profiles-cpu-partitioning`, `realtime-setup`. Profiling: `perf`,
`kernel-tools`, `numactl`. Toolchains: `gcc-c++`, `clang`, `cmake`,
`ninja-build`, `java-25-openjdk-devel`, `maven`, `python3`, `uv`, plus `jq`,
`git`, `rsync`. Containers: Docker Engine from Docker's Fedora repository
(`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`); the
guest user is in the `docker` group. No podman. The guest user `fedora` has
passwordless sudo and your `~/.ssh/id_ed25519.pub`.

## Optional peer

Set `LAB_PEER=1` to make `lab-up`, `lab-down`, `lab-ips` and `lab-status` also
manage `lowlat-peer` (provision it with `provision-vm.sh lowlat-peer`). Off by
default.

## Measurement labelling

Numbers measured in the guest are labelled `vm` and are never compared with
bare-metal numbers. Record the guest profile (vCPUs, tuned profile, pinning,
isolation) with every result.

## Conventions

- One guest, serial runs: do not fan out parallel jobs against the same VM.
- Snapshot before destructive work, revert after; bring the lab down when done.
- Stop other clusters or VMs you are not using; this lab has priority on host CPU.

`build-rt-kernel.sh` (the PREEMPT_RT kernel build) arrives in S13.
