// Replacement global allocation functions that count per thread, then defer to malloc. See
// alloc_counter.hpp. Only the counting forms are replaced; every form forwards to one of them or
// to the matching free.
#include "lowlat/eliminating/alloc_counter.hpp"

#include <cstddef>
#include <cstdlib>
#include <new>

namespace {

thread_local lowlat::eliminating::alloc::Snapshot t_counts;

void* counted(std::size_t size) {
  ++t_counts.allocations;
  t_counts.bytes += size;
  if (void* p = std::malloc(size == 0 ? 1 : size)) return p;
  throw std::bad_alloc{};
}

void* counted_aligned(std::size_t size, std::align_val_t alignment) {
  ++t_counts.allocations;
  t_counts.bytes += size;
  const auto align = static_cast<std::size_t>(alignment);
  // aligned_alloc wants a size that is a multiple of the alignment.
  const std::size_t rounded = (size + align - 1) / align * align;
  if (void* p = std::aligned_alloc(align, rounded == 0 ? align : rounded)) return p;
  throw std::bad_alloc{};
}

}  // namespace

namespace lowlat::eliminating::alloc {
Snapshot snapshot() noexcept { return t_counts; }
}  // namespace lowlat::eliminating::alloc

// The matching free() sits in operator delete, in this translation unit; GCC cannot see that the pair
// is consistent and warns with -Wmismatched-new-delete.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmismatched-new-delete"
void* operator new(std::size_t size) { return counted(size); }
void* operator new[](std::size_t size) { return counted(size); }
void* operator new(std::size_t size, std::align_val_t a) { return counted_aligned(size, a); }
void* operator new[](std::size_t size, std::align_val_t a) { return counted_aligned(size, a); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }
void operator delete(void* p, std::align_val_t) noexcept { std::free(p); }
void operator delete[](void* p, std::align_val_t) noexcept { std::free(p); }
void operator delete(void* p, std::size_t, std::align_val_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t, std::align_val_t) noexcept { std::free(p); }
#pragma GCC diagnostic pop
