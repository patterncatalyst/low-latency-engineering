---
title: "Setup: toolchains, the VM lab and the line simulator"
order: 0
part: "Prerequisites & the Lab"
description: "Fedora 44, three toolchains, Docker Engine, a KVM lab with a PREEMPT_RT guest that never touches the host, and the line simulator that feeds a consumer in C++, Python and Java."
duration: 60 minutes
---

## Learning objectives

By the end of this chapter you can:

- Check the host and the lab guest with `scripts/check-prereqs.sh` and read its PASS, WARN and FAIL lines.
- Explain why the line simulator sends on its schedule and never waits.
- Read a `lowlat-report/1` file and its machine profile.
- Provision the `lowlat-target` guest and install the PREEMPT_RT kernel without changing the host.
- Run `examples/00-prerequisites/verify.sh` and interpret its assertions.

## Why this matters

A parcel passes the scanner and the diverter has 480 ms to be told which lane to open: 1.2 m of belt at 2.5 m/s. Every technique in this book is judged against that scan-to-divert budget, and the belt never waits for a slow controller. A load generator that pauses when the consumer stalls answers a different question.

This chapter builds the instrument: the toolchains, the workload, the report format and the lab where privileged work happens. Nothing here is a latency result; the percentile columns show the pipeline carries data end to end and loses nothing.

The code is in `examples/00-prerequisites/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="00-sortation-line" alt="A conveyor carries parcels past a checkweigher, dimensioner, scanner and labeler to a diverter; the controller must sense, decide and act within the scan-to-divert deadline." caption="Figure 0.1 — The sortation line. Belt speed and the scanner-to-diverter distance set the decision deadline." %}

## The host and its toolchains

Three toolchains build the examples on Fedora 44.

- **C++20/23** with CMake. The examples tree is one CMake superproject driven by presets. The host reports GCC 16.2.1, Clang 22.1.8 and CMake 4.3.0; CMake 4.3 is the minimum.
- **Python 3.14** managed by `uv`, which builds the environment from `examples/pyproject.toml`.
- **Java 25** with Maven on the plain JVM. The host reports OpenJDK 25.0.3.

Containers use Docker Engine with the Compose plugin, on the host and in the guest, for control-plane work and throwaway builds, not a hot path.

Dependencies are pinned to exact upstream releases: protobuf 36.2 (Java 4.36.2, Python 7.36.2, one release train) with abseil 20250512.1, recorded in `versions.env`, and the HdrHistogram kits HdrHistogram_c 0.12.1, `hdrhistogram` 0.10.8 and HdrHistogram 2.2.2. The protobuf compiler is built from the pinned tarball, never Fedora's package, so all three languages generate code from one `protoc`.

### Checking the host

`scripts/check-prereqs.sh` only checks: it never installs, uses sudo or starts a VM. Each check prints one PASS, WARN or FAIL line, every WARN and FAIL carries an install hint, and the exit status is 0 unless something FAILed. It covers the compilers, zlib headers, CMake, JDK, Maven, Python, `uv`, the pinned `protoc`, Docker Engine and libvirt. With `--vm` it runs inside the guest over ssh and checks the PREEMPT_RT kernel, `cyclictest`, `ptp4l`, `tuned` and Docker.

### The machine profile

A latency number without the machine behind it is not publishable. `scripts/profile.sh` writes a `lowlat-profile/1` JSON object: CPU model and topology, scaling driver and governor, tuned profile, kernel release and preemption model, isolation parameters, clocksource, hugepages, whether the system is virtualized, the load average and the tool versions. It needs no root and writes `null` where a file is missing. Every report embeds it verbatim.

Every host number in this chapter carries one profile: bare-metal host, Intel Core i7-11800H, 16 logical CPUs, Fedora 44 kernel 7.2.11-200.fc44 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`.

## The VM lab

{% include excalidraw.html file="00-lab-topology" alt="A host band holding lab-ssh.sh, libvirt-ssh-proxy, passt and Docker Engine, with a guest band inside it holding cyclictest, linuxptp, the PREEMPT_RT kernel, Docker and the snapshots lab-ready and lab-ready-rt; an amber ssh-over-AF_VSOCK path runs from the proxy to the guest, and guest traffic leaves through passt." caption="Figure 0.2 — The lab guest is reached by ssh over vsock and networked by passt, so the host needs no NAT, bridge or firewall change. VM numbers are never compared with bare-metal numbers." %}

Real-time kernels, `isolcpus`, `tuned` and PTP change a machine, so they live in a disposable KVM guest; the host runs only unprivileged programs and Docker containers.

Every lab script keys off `LAB_PREFIX=lowlat`, so the guest is `lowlat-target`. A name guard refuses any domain not named `lowlat-*`. The lifecycle:

```bash
scripts/lab/provision-vm.sh lowlat-target   # verify image checksum, overlay disk, cloud-init, boot
scripts/lab/snapshot-vm.sh lowlat-target    # snapshot lab-ready
scripts/lab/lab-ssh.sh lowlat-target        # ssh as fedora
scripts/lab/revert-vm.sh lowlat-target      # undo a destructive run
```

Networking uses QEMU's passt backend. Guest traffic leaves through unprivileged host sockets, so there is no bridge, NAT, forwarding or firewall rule. The guest has no host-reachable address; ssh goes over AF_VSOCK through libvirt's ssh proxy, wrapped by `lab-ssh.sh`.

The guest carries `realtime-tests` (which provides `cyclictest`), `linuxptp`, `tuned`, `perf`, the toolchains and Docker Engine, and loads `ptp_kvm` at boot so `/dev/ptp0` exposes the host clock; `lab-ready` is the stock-kernel baseline. `check-prereqs.sh --vm` passes 9 of 9 guest checks, and `phc2sys` locks to `/dev/ptp0` within a few ns (`results/r01-lab/`, VM).

Fedora 44 ships no `kernel-rt`, and the stock kernel lacks `CONFIG_PREEMPT_RT`. `scripts/lab/build-rt-kernel.sh` therefore rebuilds Fedora's kernel SRPM `kernel-7.2.11-200.fc44` with the SRPM's realtime flavour plus a one-line config fragment, under the release suffix `.lowlatrt`. The build runs in a throwaway, digest-pinned `fedora:44` container, installs nothing on the host and fails unless the config contains `CONFIG_PREEMPT_RT=y`.

Installing the kernel is a guest-only step, `SNAPSHOT=lab-ready-rt scripts/lab/install-rt-kernel.sh lowlat-target`. It copies and verifies the RPMs, installs the RT kernel beside the stock one, reboots, and fails unless `uname -v` reports `PREEMPT_RT`. The snapshot `lab-ready-rt` is the revert point for the real-time chapters.

## The measurement pipeline

{% include excalidraw.html file="00-measurement-pipeline" alt="The C++ line simulator sends UDP datagrams on 127.0.0.1 at 1 kHz to the C++, Python and Java consumers in turn; each records into HdrHistogram and writes a lowlat-report/1 JSON report carrying the machine profile from profile.sh; lowlat-report check validates the schema, decodes the histogram and recomputes the percentiles." caption="Figure 0.3 — Every language records into HdrHistogram and writes the same report format, and the checker recomputes the percentiles instead of trusting them." %}

`examples/common/MEASUREMENT.md` is the contract for the measurement kits. There is one kit per language, `lowlat::measure` for C++, `lowlat_measure` for Python and `measure-java`, and they share three rules.

1. **One histogram shape.** Nanoseconds, one hour as the highest trackable value, three significant digits. Encoded histograms are interchangeable between languages.
2. **The library's own recording calls.** `hdr_record_value`, `record_value` and `recordValue` for plain samples, and the corrected variants in Part 1. No percentile code is hand-rolled.
3. **One report.** A `lowlat-report/1` JSON file holds the example, language, variant, `count`, `dropped`, the p50, p90, p99, p99.9 and max in nanoseconds, the compressed base64 histogram, the build and the embedded profile, and validates against `contracts/measurement/latency-report.schema.json`. It has no mean field. A time-average may appear only in a separate `model` block, introduced in Chapter 2.

If `LOWLAT_PROFILE` is unset the kits fail rather than write a report. The `lowlat-report` command validates a report and shows it as a table.

## The line simulator

The simulator is a C++23 program that emits one UDP datagram per parcel, each a serialized `lowlat.line.v1.ParcelEvent`: a gap-free `seq`, a valid SSCC-18 barcode, weight and dimensions from a seeded generator, an encoder tick, and two timestamps: `intended_emit_ns`, when the schedule says the parcel is due, and `actual_emit_ns`, when the simulator sent it. Both are nanoseconds on the simulator machine's `CLOCK_MONOTONIC`, so producer and consumer must share a host or a VM.

The intended time is a pure function of the parcel number, `t0 + seq * 1e9 / rate`. The simulator sleeps to that absolute deadline with `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)`, which cannot accumulate error. If it wakes late it sends at once. It never skips a parcel and never stretches the schedule, because the belt does not.

The send uses `MSG_DONTWAIT` over UDP, so a full socket buffer costs a counted drop and never a stall; TCP flow control would add backpressure the line does not have. A consumer computes `done_ns - intended_emit_ns`, never `done_ns - actual_emit_ns`. The first includes the sender's lateness and any queue in front of the consumer. The second hides both, which is how a stalled system produces a flattering distribution.

## How the code works

### The simulator's pacing

Both snippets are from `examples/common/line-simulator/`. The schedule is in `include/lowlat/line/schedule.hpp`:

```cpp
  /// t0 + i / rate, in integer nanoseconds (floor). The schedule is a pure
  /// function of i: it can never drift, whatever the sender did before.
  [[nodiscard]] constexpr std::int64_t intended_ns(std::uint64_t i) const noexcept {
    return t0_ns + static_cast<std::int64_t>(i * 1'000'000'000ULL / rate_hz);
  }
```

The loop in `src/simulator.cpp` sleeps to `intended`, stamps `actual`, sends and records its own lateness:

```cpp
    // Sleep to the absolute deadline. A signal wakes us early: stop if asked to,
    // otherwise sleep again to the same deadline. If the deadline has passed
    // this returns at once: the belt does not wait, so neither do we.
    bool woken = false;
    while (!(woken = sleep_until_ns(intended)) && !stop.load(std::memory_order_relaxed)) {
    }
    if (!woken) {
      result.interrupted = true;
      break;
    }

    const std::int64_t actual = monotonic_ns();
    ev.set_actual_emit_ns(actual);
    const std::size_t size = ev.ByteSizeLong();
    if (!ev.SerializeToArray(datagram.data(), static_cast<int>(size))) {
      throw std::runtime_error("ParcelEvent does not fit the datagram buffer");
    }
    // MSG_DONTWAIT: a full socket buffer drops this parcel instead of stalling the belt.
    if (::send(sock.get(), datagram.data(), size, MSG_DONTWAIT) == static_cast<ssize_t>(size)) {
      ++result.sent;
    } else {
      ++result.send_errors;
    }
    emit_lateness.record(std::max<std::int64_t>(0, actual - intended));
  }
```

The event is built before the sleep, off the wake-up path. `sleep_until_ns` returns false when a signal interrupts it, and the loop then sleeps to the same deadline again unless a stop was requested. `actual - intended` is clamped at zero and recorded as the `emit-lateness` variant, which the simulator prints on exit. On a kernel that is not real-time that figure is the host's wake-up jitter. A send that returns less than the datagram size is a counted `send_errors`, booked as `dropped`.

### The consumer's receive loop and handler hook

Each consumer is split in two. The loop owns what every example shares: bind, receive, parse, check `seq` against the last one seen to detect gaps and reordering, and book the gaps. What an example does with a parcel is a handler that the loop calls once per new parcel. The handler reports the parcel done through a `Completion`, which records `done_ns - intended_emit_ns` and raises an error on a negative latency, because that means the clocks differ. Later chapters swap the handler and keep the loop. The files are `consumers/cpp/include/lowlat/line/consumer.hpp`, `consumers/consumer-py/src/lowlat_consumer/loop.py` and `consumers/java/src/main/java/io/patterncatalyst/lowlat/line/LineReceiver.java`.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
  while (true) {
    if (stop.load(std::memory_order_relaxed)) {
      result.stopped_by = "signal";
      break;
    }
    if (cfg.expect && tracker.received() + tracker.dropped() >= *cfg.expect) {
      result.stopped_by = "expect";
      break;
    }

    const ssize_t n = ::recv(sock.get(), datagram.data(), datagram.size(), 0);
    if (n < 0) {
      if (errno == EINTR) continue;  // loop head sees the stop flag
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        const std::int64_t waited_ns = monotonic_ns() - last_rx_ns;
        if (started && waited_ns >= std::int64_t{cfg.idle_timeout_ms} * 1'000'000) {
          result.stopped_by = "idle";
          break;
        }
        continue;
      }
      throw std::system_error(errno, std::generic_category(), "recv");
    }
    // Every datagram, skipped or not, counts as activity for the idle timeout.
    // Stamped here, not at completion: a handler may hold parcels for a while.
    started = true;
    last_rx_ns = monotonic_ns();

    if (!ev.ParseFromArray(datagram.data(), static_cast<int>(n))) {
      ++result.malformed;
      continue;
    }
    if (tracker.observe(ev.seq()) == SeqTracker::Kind::reordered) continue;

    done.begin(ev.seq());
    handler(static_cast<const v1::ParcelEvent&>(ev), done);
  }
```

```python
    while not _stop:
        if expect is not None and tracker.accounted >= expect:
            stopped = "expect"
            break
        try:
            n = sock.recv_into(buf)
        except TimeoutError:
            if tracker.received and now() - last_rx_ns >= idle_ns:
                stopped = "idle"
                break
            continue
        # Stamped on receipt, not on completion: a handler may hold parcels for a while.
        last_rx_ns = now()
        event.ParseFromString(view[:n])
        if not tracker.observe(event.seq):
            continue
        done.seq = event.seq
        handler(event, done)
```

```java
        while (!stopRequested) {
            if (config.expect() > 0 && received + gaps.dropped() >= config.expect()) {
                return StopReason.EXPECTED;
            }
            buffer.clear();
            // Drain first: under load a datagram is already waiting, and this costs one syscall
            // rather than select + receive.
            SocketAddress source = channel.receive(buffer);
            if (source == null) {
                long timeoutMs = 0; // Selector.select(.., 0) blocks until a wakeup
                if (seenFirst) {
                    long idleLeftNs = config.idleTimeoutMs() * 1_000_000L - (System.nanoTime() - lastRxNs);
                    if (idleLeftNs <= 0) {
                        return StopReason.IDLE;
                    }
                    timeoutMs = Math.max(1, idleLeftNs / 1_000_000L);
                }
                selector.select(key -> { }, timeoutMs);
                continue;
            }
            buffer.flip();
            ParcelEvent event;
            try {
                // Direct, non-array buffer: protobuf-java reads it in place (no copy to byte[]).
                event = ParcelEvent.parseFrom(buffer);
            } catch (InvalidProtocolBufferException e) {
                malformed++;
                continue;
            }
            seenFirst = true;
            // Stamped on receipt, not on completion: a handler may hold parcels for a while.
            lastRxNs = System.nanoTime();

            if (gaps.observe(event.getSeq()) == GapTracker.Arrival.REORDERED) {
                continue; // reported in notes, not recorded twice
            }
            if (gaps.lastGap() > 0) {
                recorder.addDropped(gaps.lastGap());
            }
            received++;
            completion.begin(event.getSeq());
            handler.onParcel(event, completion);
        }
```

The C++ loop makes a blocking `recv` into a reused buffer. `EINTR` returns to the loop head to check the stop flag; `EAGAIN` means the receive timeout expired, which is how an idle stream is noticed. The receive timestamp is taken once per datagram, right after `recv` returns, and kept in `last_rx_ns` for the idle timeout. It is stamped on receipt, not completion, since a handler may hold parcels. A malformed datagram is counted and skipped; a reordered one is not handled twice.

The hook is a template parameter, not a `std::function` or a virtual interface. The call resolves at compile time and inlines into the loop, so the hook adds no indirect call or allocation to the measured path, for the same reason `std::sort` takes its comparator as a template argument. A handler may also define `drain`, which the loop calls once at the end to complete parcels it still holds.

Python reuses one `bytearray`, a `memoryview` slice so the parse does not copy, and one `ParcelEvent`, so a handler must not keep the event. A 50 ms socket timeout bounds how long a signal or idle stream goes unnoticed. The interpreter cost per datagram is on the measured path, so the Python column measures the whole consumer.

Java diverges in how it waits. `channel.receive` on a non-blocking `DatagramChannel` returns null when nothing is queued, so the loop drains first, one syscall when a datagram is waiting, and parks in a `Selector` only when the queue is empty. It parses from a direct `ByteBuffer`, which protobuf-java reads in place, and reads `System.nanoTime()`, which on Linux is the simulator's `CLOCK_MONOTONIC`. The hook is the `ParcelHandler` interface; the receiver calls one instance, so the call site is monomorphic and the JIT can inline it. All three request a 4 MiB receive buffer and print what the kernel granted.

Example 00's handler (`consumer.cpp`, `loop.py`, `LineReceiver.java`) is the lane lookup alone: the barcode picks one of 8 lanes, a stand-in for the real handling. It completes the parcel at once, so the work is inside the measured latency.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
// Example 00's handler: the lane lookup is the work, then done.
struct LaneHandler {
  std::array<std::uint64_t, kLanes> counts{};

  void operator()(const v1::ParcelEvent& ev, Completion& done) {
    ++counts[lane_for(ev.barcode())];  // the r01 "work"
    done.complete(ev);
  }
};
```

```python
def lane_handler(event: ParcelEvent, complete: Completion) -> None:
    """Example 00's handler: the lane lookup is the work, then done."""
    lane_for(event.barcode)
    complete(event.intended_emit_ns, time.monotonic_ns())
```

```java
    public StopReason run() throws IOException {
        return run((event, done) -> {
            laneCounts[Lanes.laneOf(event.getBarcode())]++; // the r01 "handle" step
            done.complete(event);
        });
```

C++ keeps its lane counts in the handler object. Python passes the event's intended time and a fresh `time.monotonic_ns()` to `complete`. Java wraps the same step in a lambda; a later chapter passes its own handler to `run(ParcelHandler)`.

Each consumer flushes stdout once its socket is bound, so a run script waiting on a ready line in a redirected stdout sees it at once, not at exit. Example 00's script polls `ss` for the bound socket instead. C++ flushes in the ready callback that `consume_with` calls once the socket is bound and sized, Python passes `flush=True` to `print`, and Java calls `System.out.flush()`.

## Measure

Run the example from the repository root:

```bash
examples/00-prerequisites/verify.sh
VM=1 ALLOW_BUSY=1 examples/00-prerequisites/verify.sh
```

The first form is the host smoke test. The script refuses to run while a `lowlat-*` guest is up, because it competes for CPU; `VM=1` needs `ALLOW_BUSY=1` to override that. It asserts:

1. `check-prereqs.sh` exits 0.
2. For each consumer in turn (C++ on UDP 47200, Python on 47201, Java on 47202, all on `127.0.0.1`) the simulator emits 1 kHz for 5 s, which is 5,000 parcels.
3. Each consumer exits 0, its report passes `lowlat-report check`, `count` is 5,000, `dropped` is 0 and the report carries a profile.

`VM=1` adds the guest smoke test: `check-prereqs.sh --vm`, `deploy-to-vm.sh`, `cyclictest -m -p95 -D60 -q` in the guest, and a captured guest profile that must report a virtual machine, in an output directory labelled `vm`.

### Host results

Three runs (`r01-run1` to `r01-run3`) on the bare-metal host above. All nine reports show `count` 5,000 and `dropped` 0, and the Java console shows 625 parcels on each of the 8 lanes. Ranges are across the three runs.

| Consumer | p50 (us) | p99 (us) | p99.9 (us) |
|---|---|---|---|
| C++ | 150.0 to 155.5 | 180.6 to 182.8 | 202.6 to 233.1 |
| Python | 105.2 to 186.1 | 202.4 to 217.7 | 236.8 to 293.6 |
| Java | 102.0 to 186.4 | 212.7 to 325.4 | 9,822.2 to 23,298.0 |

The one to read is the Java p99.9, 9.8 to 23.3 ms against p99 0.21 to 0.33 ms. The consumer's note gives the likely cause: the JIT is not warmed, so early parcels ran interpreted or on C1 and sit in a 5,000-sample histogram. The C++ and Python p99.9 over the same path stay under 0.5 ms, which points at the runtime. Part 2 covers warm-up. The point is a valid report from each, not a ranking.

### Guest result

Profile, from `r01-vm-smoke/vm/profile.json`: VM, KVM guest with 4 vCPUs on the i7-11800H host, kernel `7.2.11-200.lowlatrt.fc44.x86_64+rt` (`PREEMPT_RT`), tuned `virtual-guest`, clocksource `kvm-clock`, no CPU isolation. One `cyclictest` thread ran unpinned for 60 s at priority 95 with a 1,000 us interval, 60,000 loops. Its Max was 265 us. It shows that the RT kernel boots and `cyclictest` runs through the lab's ssh path; it is not a jitter measurement and not comparable with any bare-metal number. The measured before and after comes in Part 5.

## Cross-check

`lowlat-report check` decodes each report's compressed histogram and recomputes the percentiles with the library, so a summary bug shows up as a mismatch. The consumer's own gap accounting agrees: `received 5000, dropped 0, reordered 0, malformed 0` on the C++ console matches `count` and `dropped` in the JSON.

## What you learned

- The lab has three layers: a Fedora 44 host that only runs unprivileged programs, three pinned toolchains, and a `lowlat-` KVM guest where every privileged change happens, reached over vsock and passt.
- A report is publishable only with its machine profile; `check-prereqs.sh` and `profile.sh` describe and verify the host and the guest.
- The simulator sends on `intended_emit_ns` and never waits, and consumers measure from that intended time, so lateness and queueing stay in the distribution.
- Each consumer is a receive, parse and gap-check loop that calls a per-parcel handler in C++, Python and Java; they diverge in how they wait, how they bind the hook and how they avoid copies.
- A VM number is labelled VM, and the smoke test proves the pipeline, not a latency.

Next, Chapter 1 uses this workload to show that latency is a distribution.

## For deeper coverage

- Enberg, *Latency* (Manning), as further reading on measuring and reasoning about latency.
- Chapter 1, *Latency vs bandwidth*, and Chapter 3, *Measuring correctly*, in Part 1, for what the percentile columns mean and how coordinated omission corrupts them.
- Chapter 5, *What the JVM costs*, in Part 2, for JIT warm-up, and Part 5 for the `cyclictest` jitter measurement.
- `examples/common/MEASUREMENT.md` and `scripts/lab/README.md` for the kit and lab references.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts that `check-prereqs.sh` exits 0, that each of the C++, Python and Java consumers exits 0 after receiving 5,000 datagrams at 1 kHz for 5 s with `dropped` 0, and that each report passes `lowlat-report check` and carries the machine profile. It held on the host runs `r01-run1` to `r01-run3`. The `VM=1` guest smoke test ran once against the PREEMPT_RT guest (`r01-vm-smoke`).*
