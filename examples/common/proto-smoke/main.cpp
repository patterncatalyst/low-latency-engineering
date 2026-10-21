// Builds a ParcelEvent, serializes, parses it back and prints the wire size.
#include <cstdlib>
#include <iostream>
#include <string>

#include "lowlat/line/v1/parcel.pb.h"

int main() {
  lowlat::line::v1::ParcelEvent in;
  in.set_seq(42);
  in.set_intended_emit_ns(1'000'000'000);
  in.set_actual_emit_ns(1'000'000'350);
  in.set_encoder_tick(8'400);
  in.set_barcode("003412345678901234");
  in.set_weight_g(2'350);
  in.set_scan_confidence_permille(987);
  auto* d = in.mutable_dims();
  d->set_length_mm(400);
  d->set_width_mm(300);
  d->set_height_mm(150);

  std::string wire;
  if (!in.SerializeToString(&wire)) return EXIT_FAILURE;

  lowlat::line::v1::ParcelEvent out;
  if (!out.ParseFromString(wire) || out.seq() != in.seq() || out.barcode() != in.barcode())
    return EXIT_FAILURE;

  std::cout << "serialized " << wire.size() << " bytes\n";
  return EXIT_SUCCESS;
}
