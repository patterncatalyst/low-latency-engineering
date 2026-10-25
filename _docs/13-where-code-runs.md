---
title: "Where the code runs: bare metal, VMs and containers, and when not to use containers"
order: 13
part: "Threading & I/O Models"
description: "On this machine, in this run, the same decide path shows a simulator emit-lateness p99 of 62-64 us on the bare-metal host, 80-83 us in a VM and 85-103 us in a container behind a bridge; --cpus=2 raised the consumer p99.9 13.16-18.91x over --cpuset-cpus=2,3, and io_uring_setup returned EPERM in every container."
duration: 55 minutes
---

## Learning objectives

By the end of this chapter you can:

- Name what a VM and a container each add under the decide path (steal, a veth and a bridge, a cgroup, a seccomp filter) and read the counter that shows each one.
- Choose between `--cpus` and `--cpuset-cpus` from what each does to a running cgroup, and read `nr_throttled` and `throttled_usec` to see it.
- Predict what `hardware_concurrency()`, `os.process_cpu_count()` and `availableProcessors()` report under each limit, and size pools from the cgroup.
- Say which paths belong in a container and which don't.

## Why this matters

The controller PC under the conveyor runs the decide service beside the tunnel. In the hub's VM farm the same service is one tenant among many, and in a pod it's a container inside a VM that someone else sized. The binary doesn't change. The floor under it, the path in front of it and what its runtime believes about the CPUs do.

A parcel has 480 ms from scan to divert ([Chapter 2, *Modelling with Little's Law and Amdahl's Law*]({{ '/docs/02-littles-amdahl/' | relative_url }})), and a stall charges every parcel behind it ([Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*]({{ '/docs/03-coordinated-omission/' | relative_url }})). A 50 ms stall is a tenth of that.

The consumer is [Chapter 12's]({{ '/docs/12-io-engines/' | relative_url }}) `epoll` receiver, pinned to one CPU, and the load is the Chapter 2 line: four simulators as four cameras at 2.5 kHz each, 10 kHz together, for 20 s. The code is in `examples/13-where-code-runs/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="13-three-places" alt="Nested bands: a bare-metal host holds a KVM guest with 4 vCPUs, which holds a Docker container. Lane host: simulators and consumer on the host; emit lateness p99 62-64 us and consumer p99 97-98 us. Lane vm: native in the guest, which adds VM exits and steal, with steal ticks 0-1 of 8,848-9,886 guest ticks; emit lateness p99 80-83 us and consumer p99 99-101 us. Lane container-host-net: the guest's network namespace and Docker's default seccomp filter, under which io_uring_setup returns EPERM; emit lateness p99 81-89 us and consumer p99 101-104 us. Lane container-bridge: the simulators run in the guest and the consumer in the container, behind a veth and the bridge; emit lateness p99 85-103 us and consumer p99 105-140 us." caption="Figure 13.1: Each lane is measured inside one run, at 10 kHz for 20 s. Emit lateness p99 is 62-64 us in the host lane, 80-83 us in the vm lane and 85-103 us in the container-bridge lane. Observed: the bridge lane's consumer p99 is 105-140 us against 101-104 us in container-host-net. The host and the guest differ in kernel and clock, so host against vm is not a claim." %}

## Concept

### A container is a cgroup, not a smaller machine

Take the consumer in the pod. To the kernel it's an ordinary process with three wrappers: namespaces, which give it its own view of the network and the PIDs; a cgroup, which limits what it may use; and a seccomp filter, which limits what it may call. None of them shrinks the machine. `/sys/devices/system/cpu/online` still lists every CPU of the guest, and a runtime that reads it sizes its pools from CPUs the container can't have.

A VM adds a different layer. The guest's vCPUs are threads of the host's scheduler, so the hypervisor can take a CPU away mid-run. The guest counts that as steal ticks in `/proc/stat`, in units of 10 ms.

### Quota against cpuset

Take a pod with four busy workers beside the consumer, given two CPUs two ways. `--cpus=2` sets `cpu.max` to `200000 100000`: 200 ms of CPU time per 100 ms period, on any CPU. Docker's default period is 100 ms. The scheduler's bandwidth control lets the cgroup's threads run on all four vCPUs until the 200 ms is spent, then stops every one of them until the period edge. A pool of four busy workers on four vCPUs spends the budget in 50 ms, and the whole cgroup, the consumer included, waits out the other 50. `--cpuset-cpus=2,3` sets a mask: two CPUs and no budget. The same threads time-slice on those two, and nothing is stopped for a spent allowance.

{% include excalidraw.html file="13-quota-vs-cpuset" alt="Two lanes of three 100 ms CFS periods, drawn for illustration. Lane container-cpu-quota (--cpus=2, 200 ms of CPU per 100 ms period): the four busy workers beside the consumer spend the quota early and the cgroup is throttled to the period edge (amber); nr_throttled is 206-207, throttled time 37.8-40.7 s (summed over the guest's 4 CPUs), and the consumer p99.9 is 53,411-55,574 us. Lane container-cpuset (--cpuset-cpus=2,3): two CPUs, no budget and no gaps; nr_throttled is 0, throttled time 0.0 s, and the consumer p99.9 is 2,912-4,067 us. The quota over cpuset p99.9 ratio is 13.16-18.91x." caption="Figure 13.2: Both lanes give the container two CPUs, but only the quota stops the cgroup until the period edge. The consumer p99.9 is 53,411-55,574 us under --cpus=2 and 2,912-4,067 us under --cpuset-cpus=2,3, a ratio of 13.16-18.91x." %}

### What the runtime thinks it has

A decide pool starts by asking how many CPUs it has, and each runtime answers differently. C++ `hardware_concurrency()` returns glibc's `get_nprocs()`, which reads the online list, so neither limit moves it. Python's `os.process_cpu_count()` follows the affinity mask: a cpuset shows, a quota doesn't. JDK 25's `availableProcessors()` starts from the mask and then divides the quota by the period, rounded up, so both limits show. The JVM sizes its virtual-thread scheduler and its GC threads from that number.

{% include excalidraw.html file="13-cpu-count-views" alt="Two panels, one per limit, each with a limit box feeding four answers. Lane container-cpu-quota (--cpus=2): C++ hardware_concurrency() says 4 (amber, it ignores the limit), with an affinity mask of 4, a cgroup-aware pool of 2 and a pool by hardware_concurrency of 4; Python process_cpu_count() says 4 (amber) and os.cpu_count() says 4; Java availableProcessors() says 2, with a virtual-thread scheduler of 2 and 2 GC threads; the Quarkus service has 2 event-loop threads running and 8 workers fixed in application.properties. Lane container-cpuset (--cpuset-cpus=2,3): C++ says 4 (amber), with an affinity mask of 2, a cgroup-aware pool of 2 and a pool by hardware_concurrency of 4; Python process_cpu_count() says 2 and os.cpu_count() says 4; Java says 2, with a scheduler of 2 and 2 GC threads; Quarkus has the same 2 event-loop threads running and 8 fixed workers; those come from configuration and lazy thread creation, not from the CPU view. In the vm lane, 4 vCPUs and no limit, C++, Python and Java all say 4." caption="Figure 13.3: A container is a cgroup, not a smaller machine. Under --cpus=2, C++ and Python still say 4 and Java says 2; under --cpuset-cpus=2,3 Python follows the mask and says 2, while C++ hardware_concurrency() still says 4." %}

### Seccomp and io_uring

The Chapter 12 receiver asks the kernel for a ring with `io_uring_setup`. Docker's default seccomp profile denies by default and lists no `io_uring_setup`, `io_uring_enter` or `io_uring_register`; that has held since Engine 25.0. A program that probes io_uring in a container gets `EPERM`, and an I/O engine from Chapter 12 can't start there.

## How the code works

### What a runtime reports

`place-probe` (C++), `python -m lowlat_place` and `CpuProbe` (Java) each write what their runtime reports. The same files run in every lane. Python appears in this tab set and nowhere else in the chapter: there's no Python latency lane, so CPU counts are the whole Python lane.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
  const std::size_t hardware = std::thread::hardware_concurrency();
  const std::size_t affinity = affinity_count();
```

```python
    return {
        "cpu_count": os.cpu_count(),
        "process_cpu_count": os.process_cpu_count(),
        "affinity_count": len(os.sched_getaffinity(0)),
    }
```

```java
    public static int availableProcessors() {
        return Runtime.getRuntime().availableProcessors();
    }

    // ...

        java.put("virtual_thread_parallelism", scheduler().getParallelism());

        // ...

        java.put("parallel_gc_threads", vmOption("ParallelGCThreads"));
```

### Sizing a pool

`busy-pool` is the load for the quota lane, and its default is the rule most pools use: one worker per hardware thread (#A). On the 4-vCPU guest that's 4 whatever the container is allowed, which is what lets the lane offer more CPU time than `--cpus=2` grants. `place-probe` also computes the size a cgroup-aware rule would pick (#B): the smallest of the hardware count, the quota rounded up and the cpuset.

```cpp
  const std::size_t workers = options.number("workers", std::thread::hardware_concurrency());
```

```cpp
  std::size_t aware = hardware;
  if (quota && *quota > 0) aware = std::min(aware, static_cast<std::size_t>(*quota));
  if (cpuset && *cpuset > 0) aware = std::min(aware, *cpuset);
```

In #A the pool size belongs to the guest. In #B it belongs to the cgroup: 2 under either limit, 4 in the VM lane.

### The two limits

The lanes differ by one flag. `guest-run.sh` runs both through `container_run`, which allows only `--network`, `--cpus`, `--cpuset-cpus`, the default seccomp profile and bind mounts under one output directory.

```bash
    container-cpu-quota) limit=(--cpus "$LIMIT_CPUS") ;;
```

```bash
    container-cpuset) limit=(--cpuset-cpus "$LIMIT_CPUSET") ;;
```

#A budgets CPU time and leaves the placement to the scheduler. #B fixes the placement and budgets nothing.

### The seccomp probe

`place-probe` calls `io_uring_setup` through the raw system call, not liburing, so nothing sits between it and the answer of the kernel or the filter.

```cpp
std::error_code io_uring_setup_error() noexcept {
  io_uring_params params{};
  const long fd = ::syscall(SYS_io_uring_setup, 8U, &params);
  if (fd < 0) return {errno, std::generic_category()};
  ::close(static_cast<int>(fd));
  return {};
}
```

## Measure

Run from the repository root:

```bash
VM=1 examples/13-where-code-runs/verify.sh
```

It reverts the guest to snapshot `lab-ready-r04`, interleaves six lanes three times and evaluates; `RECHECK=results/<run-id>` re-evaluates committed reports. Every comparison is inside one run, and a latency figure is the median of three alternations. Every number is labelled with its lane and means "on this machine, in this run".

One line per lane:

- `host`: the bare-metal host with the VM booted and idle (3 permille busy across every host alternation). Fedora 44, kernel 7.2, `powersave` governor, tuned `balanced`, untuned, a desktop session running (busy share 22-55 permille across the host alternations). The consumer sits on one CPU and the simulators on the rest, except CPU 0's core.
- `vm`: `lowlat-target`, guest profile `stock-unpinned`, snapshot `lab-ready-r04`: 4 vCPUs, unpinned, stock Fedora kernel 7.2, tuned `virtual-guest`, Docker Engine 29.9.2. The consumer is on guest CPU 3.
- `container-host-net`: `place-cpp:r04` below, `--network host`, no limit, default seccomp.
- `container-bridge`: the same image on the default bridge, no limit, default seccomp. The simulators run in the guest, so every datagram crosses the veth and the bridge to the consumer in the container.
- `container-cpu-quota`: the same image, `--cpus=2`, a busy pool of 4, default seccomp.
- `container-cpuset`: the same image, `--cpuset-cpus=2,3`, a busy pool of 4, default seccomp.

The images, from `containers/IMAGES.lock`, on UBI 10.2 minimal:

```text
lowlat/place-cpp:r04@sha256:007fe524247daaa80220d5cc80b3222ba51a4bef347e7f058dafd1c6c9fde05f
lowlat/place-java:r04@sha256:da6684ca44f28935abe38ea3907a42f78197f64851962a008e36c4c52b488cc7
lowlat/place-py:r04@sha256:276c666a61652b183d9a452608531d76d8686d2a54e2ec50fc53cbe3a9deed31
```

The four C++ binaries were built once in the UBI 10 image and run unchanged in all six lanes. Ranges span the committed runs `r04-run1` to `r04-run3`.

### Three places

Every lane and alternation received 200,000 parcels and dropped none (exact). Four cameras feed one consumer per lane. Latency is measured from the intended emit time, so the simulator's emit lateness is part of every consumer figure and is the floor under it.

| Lane | Emit lateness p99 | Consumer p99 | Consumer p99.9 |
|---|---|---|---|
| `host` | 62-64 us | 97-98 us | 195-264 us |
| `vm` | 80-83 us | 99-101 us | 145-161 us |
| `container-host-net` | 81-89 us | 101-104 us | 142-153 us |
| `container-bridge` | 85-103 us | 105-140 us | 167-211 us |

All of this is observed. On the host the emit-lateness range sits below the others in these three runs, and that's all it says: the host and the guest differ in kernel and clock, so the host against the VM is printed and not compared as a claim. The container lanes are measured against `vm`, the same guest. `container-host-net` and `vm` overlap on emit lateness (81-89 and 80-83 us) and on the consumer p99 (101-104 and 99-101 us).

### The network namespace

With the consumer behind the veth, the consumer p99 was above `container-host-net`'s in all three runs: 1.39x, 1.05x and 1.03x, or 39, 5 and 3 us. Each is under 2x, so it's observed and not asserted.

### The quota and the cpuset

The counters are exact. Under `--cpus=2`, `nr_throttled` was 206-207 and `throttled_usec` 37.8-40.7 s, summed over the guest's 4 CPUs, which is why it exceeds the 20 s run. Under `--cpuset-cpus=2,3` both were 0.

| Lane | Consumer p50 | Consumer p99 | Consumer p99.9 |
|---|---|---|---|
| `container-cpu-quota` | 4,730-4,923 us | 50,462-51,642 us | 53,411-55,574 us |
| `container-cpuset` | 60 us | 2,085-3,043 us | 2,912-4,067 us |

Asserted: the quota lane's p99.9 is at least 2x the cpuset lane's, as the median of three alternations. It was 18.91x, 13.16x and 18.34x, so the smallest margin over the 2x bound is 6.58x. Within each run the quota lane's p50 was in milliseconds against 60 us. The cpuset lane isn't clean: up to nine runnable threads share two CPUs, and its p99 of 2.1-3.0 ms is what time-slicing looks like. A cpuset removes the stall but not the contention; isolation is Part 5's subject.

The Quarkus service from Chapter 12 ran under both limits too. Its p99 (median of three alternations) was 4.1, 5.0 and 5.9 ms under the quota against 3.7, 10.1 and 12.4 ms under the cpuset. The order flips between runs, and the client shares the guest's CPUs, so there's no claim here.

### What each runtime thinks it has

| View | `vm` | `container-cpu-quota` | `container-cpuset` |
|---|---|---|---|
| C++ `hardware_concurrency()` | 4 | 4 | 4 |
| C++ pool by the hardware count / the cgroup | 4 / 4 | 4 / 2 | 4 / 2 |
| Python `os.cpu_count()` / `os.process_cpu_count()` | 4 / 4 | 4 / 4 | 4 / 2 |
| Java `availableProcessors()` | 4 | 2 | 2 |
| Java virtual-thread scheduler parallelism | 4 | 2 | 2 |
| Java parallel GC threads (observed) | 4 | 2 | 2 |

These are exact counts, identical in all nine alternations. The Quarkus service ran 2 event-loop threads and 8 workers in both container lanes, and neither number comes from the CPU view: the 8 workers are fixed in `application.properties`, and the event loops are created lazily, so 2 is the count running. The rule that works is to size pools from the cgroup or pass the number explicitly.

### Seccomp

`io_uring_setup` returned `EPERM` (errno 1) in all 36 probes across the four container lanes, and 0 in all 9 `vm` probes, with the same binary. On the host it also returned 0 (observed). The Engine here is 29.9.2, past the 25.0 change.

### When not to use a container

The hot path, scan to divert, doesn't belong in a container under a CPU quota. The quota stops the whole group at once, not the busy thread, so a busy neighbour in the cgroup turns into a 50 ms stall for the consumer. It doesn't belong where the I/O engine is filtered either: a default-seccomp container can't use io_uring. If the decide path must live in one, give it `--network host` or a cpuset, size pools from the cgroup, and expect the cpuset lane's contention; a bridge adds a hop that, here, cost 3 to 39 us at p99.

The control plane, telemetry and analytics are fine in containers: they want a reproducible filesystem and tolerate a stall. In a Kubernetes pod the limits come from requests and limits, and the QoS class follows from them; the kubelet's CPU Manager `static` policy gives a Guaranteed pod with whole-CPU requests exclusive CPUs, which is the cpuset case managed for you. Chapter 18, *Latency config as code: CI/CD, deployment, and rollouts gated on a latency and jitter SLO*, gates a rollout on a latency and jitter SLO, not on a health check.

## Cross-check

The counters explain the tails. In the quota lane, `throttled_usec` over `nr_throttled` over the 4 vCPUs is 45.9-49.2 ms per CPU per period, nearly the 50 ms the arithmetic predicts (100 ms less 200 ms of budget spread over four CPUs). The consumer's p99 was 50,462-51,642 us, and its p90 41-42 ms: about half the run was a stall, and the percentiles trace its length. The cpuset lane had no throttling and a p90 of 168-557 us.

Steal ticks are the cross-check on the VM's floor. The `vm` lane showed 0-1 ticks in all nine alternations, of 8,848-9,886 guest ticks: at most 10 ms stolen in a 20 s lane. The 80-83 us emit-lateness p99 can't come from sustained steal. A tick is 10 ms, so steal that comes as microsecond VM exits isn't visible in `/proc/stat`. The container lanes showed up to 10 ticks (`container-bridge`, run 1, alternation 2). The counter bounds sustained steal; it doesn't explain the floor.

## What you learned

- A container is a cgroup, namespaces and a seccomp filter on the guest's kernel; it doesn't shrink the machine, and a VM adds steal and a floor of its own.
- `--cpus=2` stops the whole cgroup until the period edge: `nr_throttled` 206-207 against 0, and a consumer p99.9 of 13.16-18.91x the `--cpuset-cpus=2,3` lane's.
- `hardware_concurrency()` said 4 under both limits, `os.process_cpu_count()` followed only the cpuset, and Java followed both.
- Docker's default seccomp returned `EPERM` for `io_uring_setup` in every container lane.
- Host against VM is observed only; container costs are measured against the VM in the same guest.

The next chapter, *PREEMPT_RT: what real-time Linux does and doesn't promise* (Part 5), starts the isolation this chapter only points at.

## For deeper coverage

- Williams, *C++ Concurrency in Action* (Manning), and Grimm, *Concurrency with Modern C++* (Leanpub), for `hardware_concurrency()` and thread pools; Bobrov, *Grokking Concurrency* (Manning), for the concepts behind them.
- Tanenbaum and Bos, *Modern Operating Systems* (Pearson), for scheduling and virtualization.
- Evans and Gough, *Optimizing Cloud Native Java* (O'Reilly), for JVM container ergonomics.
- Andrist and Sehr, *C++ High Performance* (Packt), and Ghosh, *Building Low Latency Applications with C++* (Packt), for C++ concurrency; Enberg, *Latency* (Manning), as further reading.
- Ibryam and Huß, *Kubernetes Patterns* (O'Reilly), for resource requests, limits and QoS classes; Rice, *Container Security* (O'Reilly), for namespaces, cgroups and seccomp.
- Companion sites: [cpp-concurrency-and-parallelism, Chapter 32, Concurrency in Containers](https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/docs/32-concurrency-in-containers/); linux-systems-programming, [32 Namespaces and cgroups](https://patterncatalyst.github.io/linux-systems-programming/docs/32-namespaces-and-cgroups/), [34 Our programs in containers](https://patterncatalyst.github.io/linux-systems-programming/docs/34-our-programs-in-containers/) and [35 Virtualization and KVM](https://patterncatalyst.github.io/linux-systems-programming/docs/35-virtualization-and-kvm/); [quarkus-optimization](https://patterncatalyst.github.io/quarkus-optimization/) for JVM container ergonomics in depth; [cpp-container-optimization-tutorial](https://patterncatalyst.github.io/cpp-container-optimization-tutorial/).
- [Chapter 12, *I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core*]({{ '/docs/12-io-engines/' | relative_url }}), for the consumer, and Chapter 15, *CPU partitioning and the noisy-neighbour problem* (Part 5), for isolation.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts the cgroup counters (`nr_throttled` and `throttled_usec` at least 1 under `--cpus=2` and 0 under `--cpuset-cpus=2,3`), the CPU counts each runtime reports, `EPERM` from `io_uring_setup` in every container lane and success in the VM lane, a consumer p99.9 under the quota of at least 2x the cpuset's, and, for every lane and alternation, 200,000 parcels, 0 dropped, the lane's environment record and the image digest. Observed only: host against VM, bridge against host network, emit lateness per lane, steal ticks, the Quarkus p99 under the two limits and the GC thread counts. It held on `r04-run1` to `r04-run3` at commit 4434ed1. Host: bare metal, untuned, the VM booted and idle. VM: `stock-unpinned`, snapshot `lab-ready-r04`. Containers: `place-cpp:r04@sha256:007fe524247d…`, `place-java:r04@sha256:da6684ca44f2…`, `place-py:r04@sha256:276c666a6165…`, full digests above.*
