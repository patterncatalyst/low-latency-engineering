// Memory counters read from /proc: the process's resident set and the page tables behind it
// (/proc/self/status), and the kernel stacks the whole system holds (/proc/meminfo KernelStack).
#pragma once

#include <cstdint>
#include <optional>
#include <string_view>

namespace lowlat::tasks {

/// The value of "Key:   123 kB" in `file` (kibibytes), or nullopt when the file or key is missing.
[[nodiscard]] std::optional<std::int64_t> proc_kib(std::string_view file, std::string_view key);

struct MemorySnapshot {
  std::int64_t rss_kib = 0;           ///< VmRSS: resident pages of this process
  std::int64_t vm_size_kib = 0;       ///< VmSize: address space reserved by this process (stacks included)
  std::int64_t page_tables_kib = 0;   ///< VmPTE: page-table pages of this process
  std::int64_t kernel_stack_kib = 0;  ///< KernelStack, system-wide (16 KiB per thread on x86-64)
};

/// Reads all three; a missing key counts as 0.
[[nodiscard]] MemorySnapshot memory_snapshot();

}  // namespace lowlat::tasks
