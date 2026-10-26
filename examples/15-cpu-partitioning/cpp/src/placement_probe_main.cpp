// placement-probe [--cpu N] [--busy-ms N]
// Pins the main thread (when --cpu is given), spins, and prints one lowlat-placement-probe/1 JSON object.
#include <charconv>
#include <cstdlib>
#include <print>
#include <string_view>

#include "placement.hpp"

namespace {

bool parse(std::string_view text, int& out) {
  const auto [end, ec] = std::from_chars(text.data(), text.data() + text.size(), out);
  return ec == std::errc{} && end == text.data() + text.size();
}

}  // namespace

int main(int argc, char** argv) {
  int cpu = -1;
  int busy_ms = 100;
  for (int i = 1; i < argc; i += 2) {
    const std::string_view key{argv[i]};
    int* target = key == "--cpu" ? &cpu : key == "--busy-ms" ? &busy_ms : nullptr;
    if (target == nullptr || i + 1 >= argc || !parse(argv[i + 1], *target)) {
      std::println(stderr, "usage: placement-probe [--cpu N] [--busy-ms N]");
      return EXIT_FAILURE;
    }
  }
  const auto result = lowlat::placement::probe(cpu, std::chrono::milliseconds{busy_ms});
  if (!result) {
    std::println(stderr, "placement-probe: {}", result.error());
    return EXIT_FAILURE;
  }
  std::println("{}", result->dump(2));
  return EXIT_SUCCESS;
}
