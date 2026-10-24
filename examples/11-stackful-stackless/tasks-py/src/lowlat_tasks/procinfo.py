"""Memory counters from /proc.

The process's resident set and address space, its page tables, and the
kernel stacks the whole system holds (/proc/meminfo KernelStack)."""

from dataclasses import dataclass
from pathlib import Path


def kib(file: str, key: str) -> int:
    """The value of `Key:   123 kB` in `file` in kibibytes; 0 when the key is absent."""
    prefix = key + ":"
    for line in Path(file).read_text(encoding="ascii").splitlines():
        if line.startswith(prefix):
            return int(line[len(prefix) :].split()[0])
    return 0


@dataclass(frozen=True)
class Memory:
    rss_kib: int
    vm_size_kib: int
    page_tables_kib: int
    kernel_stack_kib: int


def memory() -> Memory:
    status = "/proc/self/status"
    return Memory(
        rss_kib=kib(status, "VmRSS"),
        vm_size_kib=kib(status, "VmSize"),
        page_tables_kib=kib(status, "VmPTE"),
        kernel_stack_kib=kib("/proc/meminfo", "KernelStack"),
    )


def memory_counters(before: Memory, parked: Memory, tasks: int) -> dict[str, int]:
    """Exact kernel-reported readings and their growth, per task in bytes."""
    rss = max(0, parked.rss_kib - before.rss_kib)
    vsize = max(0, parked.vm_size_kib - before.vm_size_kib)
    pte = max(0, parked.page_tables_kib - before.page_tables_kib)
    kstack = max(0, parked.kernel_stack_kib - before.kernel_stack_kib)
    return {
        "rss_before_kib": before.rss_kib,
        "rss_parked_kib": parked.rss_kib,
        "rss_delta_kib": rss,
        "rss_bytes_per_task": rss * 1024 // tasks,
        "vm_size_delta_kib": vsize,
        "vm_size_bytes_per_task": vsize * 1024 // tasks,
        "page_tables_delta_kib": pte,
        "kernel_stack_delta_kib": kstack,
        "rss_page_tables_kernel_stack_bytes_per_task": (rss + pte + kstack) * 1024 // tasks,
    }
