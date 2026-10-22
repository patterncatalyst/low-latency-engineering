from lowlat_proto import divert_pb2, parcel_pb2


def test_parcel_event_round_trip() -> None:
    event = parcel_pb2.ParcelEvent(
        seq=7,
        intended_emit_ns=123_456_789,
        barcode="003412345678901234",  # string: leading zeros survive
        dims=parcel_pb2.Dimensions(length_mm=400),
    )
    wire = event.SerializeToString()
    out = parcel_pb2.ParcelEvent.FromString(wire)
    assert out == event
    assert out.barcode == "003412345678901234"
    assert out.dims.length_mm == 400


def test_lane_enum_zero_is_unspecified() -> None:
    assert divert_pb2.Lane.Name(0) == "LANE_UNSPECIFIED"
