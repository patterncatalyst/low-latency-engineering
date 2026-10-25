// Ch13: an external-linkage sink for the busy loops. The definition lives in another translation unit,
// so the compiler cannot prove the spin has no effect and remove it.
#pragma once

#include <cstdint>

namespace lowlat::place {

void sink(std::uint64_t value) noexcept;
[[nodiscard]] std::uint64_t sink_value() noexcept;

}  // namespace lowlat::place
