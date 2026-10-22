#include "lowlat/gctails/tracker.hpp"

#include <algorithm>
#include <format>
#include <utility>

#include "lowlat/line/consumer.hpp"

namespace lowlat::gctails {

std::optional<Policy> parse_policy(std::string_view variant) noexcept {
  for (const Policy p : {Policy::bulk_free, Policy::deferred_free, Policy::no_free}) {
    if (variant == name(p)) return p;
  }
  return std::nullopt;
}

std::string_view name(Policy policy) noexcept {
  switch (policy) {
    case Policy::bulk_free: return "bulk-free";
    case Policy::deferred_free: return "deferred-free";
    case Policy::no_free: return "no-free";
  }
  return "unknown";
}

std::string synthetic_barcode(std::uint64_t n) { return std::format("{:08}{:09}{}", 0, n % 1'000'000'000U, 0); }

void Reclaimer::run(const std::stop_token& stop) {
  std::unique_lock lock{mutex_};
  while (true) {
    // With a stop token the wait also returns when a stop is requested; then drain what is queued.
    wake_.wait(lock, stop, [this] { return !queue_.empty(); });
    if (queue_.empty()) return;
    Wave wave = std::move(queue_.front());
    queue_.pop();
    lock.unlock();
    const auto entries = wave.size();
    wave = Wave{};  // the frees: seven heap blocks per entry, on this thread
    reclaimed_.fetch_add(entries, std::memory_order_relaxed);
    lock.lock();
  }
}

void Reclaimer::finish() {
  thread_.request_stop();
  thread_.join();
}

Tracker::Tracker(Policy policy, const Settings& settings)
    : policy_(policy),
      settings_(settings),
      in_flight_capacity_(std::max<std::size_t>(1, settings.rate * static_cast<std::uint64_t>(settings.in_flight_ms) / 1000)) {
  current_.reserve(settings_.wave_parcels);
  in_flight_.reserve(in_flight_capacity_ * 2);
  if (policy_ == Policy::deferred_free) reclaimer_.emplace();
}

Entry Tracker::make_entry(std::string_view barcode, std::uint64_t seq) const {
  Entry entry{.barcode = std::string{barcode}, .label = std::vector<std::byte>(settings_.entry_bytes), .stages = {}, .seq = seq};
  entry.stages.reserve(settings_.stages);
  for (std::size_t i = 0; i < settings_.stages; ++i) {
    entry.stages.emplace_back(24, static_cast<char>('a' + static_cast<int>(i % 26)));  // past the small-string size
  }
  return entry;
}

unsigned Tracker::track(std::string_view barcode, std::uint64_t seq) {
  const unsigned lane = line::lane_for(barcode);
  current_.push_back(make_entry(barcode, seq));

  in_flight_.try_emplace(std::string{barcode}, State{.seq = seq, .lane = lane});
  in_flight_order_.emplace_back(barcode);
  if (in_flight_order_.size() > in_flight_capacity_) {  // diverted: the eldest leaves the belt
    in_flight_.erase(in_flight_order_.front());
    in_flight_order_.pop_front();
  }

  if (current_.size() >= settings_.wave_parcels) close_wave();
  return lane;
}

void Tracker::close_wave() {
  Wave dead = std::move(previous_);
  previous_ = std::move(current_);
  current_ = Wave{};
  current_.reserve(settings_.wave_parcels);
  ++waves_closed_;
  switch (policy_) {
    case Policy::bulk_free:
      destroyed_inline_ += dead.size();  // `dead` is destroyed when this function returns, on this thread
      break;
    case Policy::deferred_free:
      reclaimer_->submit(std::move(dead));
      break;
    case Policy::no_free:
      retained_entries_ += dead.size();
      retained_.push_back(std::move(dead));
      break;
  }
}

void Tracker::finish() {
  if (reclaimer_) reclaimer_->finish();
}

}  // namespace lowlat::gctails
