"""Python lane of Ch8: ``unpack_from`` over a ``memoryview`` against ``ParseFromString``.

There is no flyweight in CPython. Both paths end with a Python ``int`` for every numeric field
that is read, so "zero-copy" here means the datagram bytes are not copied, not that nothing is
allocated. ``observe_allocations`` counts what each path creates per parcel; ``time_decodes``
records the per-call time with the lowlat recorder (percentiles, no mean).
"""

import gc
import sys
import time
from collections.abc import Callable
from typing import Any

from lowlat_consumer import flat
from lowlat_measure import Recorder
from lowlat_proto import parcel_pb2

EXAMPLE = "08-zero-copy-flat"
UNPACK_FROM = "unpack-from"
PARSE_FROM_STRING = "parse-from-string"
VARIANTS = (UNPACK_FROM, PARSE_FROM_STRING)

# CPython caches the ints from -5 to 256: reading a field with a larger value creates a new object.
_SMALL_INT_MAX = 256
_SMALL_INT_MIN = -5

type Decode = Callable[[int], tuple[Any, ...]]


def sample_parcels(count: int) -> list[parcel_pb2.ParcelEvent]:
    """Parcels with line-like values (same shape as the Java ``SampleWire``)."""
    events = []
    for seq in range(count):
        intended = 5_000_000_000_000 + seq * 100_000
        events.append(
            parcel_pb2.ParcelEvent(
                seq=seq,
                intended_emit_ns=intended,
                actual_emit_ns=intended + (seq * 7919) % 50_000,
                encoder_tick=seq // 4,
                barcode=f"{(seq * 2_654_435_761) % 10**18:018d}",
                weight_g=100 + (seq * 104_729) % 29_900,
                dims=parcel_pb2.Dimensions(
                    length_mm=100 + (seq * 31) % 700,
                    width_mm=100 + (seq * 17) % 500,
                    height_mm=50 + (seq * 13) % 450,
                ),
                scan_confidence_permille=300 + (seq * 7) % 700,
            )
        )
    return events


def encode_flat(events: list[parcel_pb2.ParcelEvent]) -> bytes:
    """The same parcels as back-to-back parcel-v1 records."""
    return b"".join(
        flat.encode(
            flat.ParcelV1(
                weight_g=e.weight_g,
                seq=e.seq,
                intended_emit_ns=e.intended_emit_ns,
                actual_emit_ns=e.actual_emit_ns,
                encoder_tick=e.encoder_tick,
                length_mm=e.dims.length_mm,
                width_mm=e.dims.width_mm,
                height_mm=e.dims.height_mm,
                scan_confidence_permille=e.scan_confidence_permille,
                barcode=e.barcode,
            )
        )
        for e in events
    )


def unpack_decoder(wire: bytes) -> Decode:
    """Decode record ``i`` with ``unpack_from`` over one ``memoryview`` of ``wire``."""
    view = memoryview(wire)
    unpack_from = flat.RECORD.unpack_from

    def decode(i: int) -> tuple[Any, ...]:
        return unpack_from(view, i * flat.SIZE)

    return decode


def parse_decoder(events: list[parcel_pb2.ParcelEvent]) -> Decode:
    """Decode message ``i`` with ``ParseFromString`` and read the same fields the tuple holds."""
    wires = [e.SerializeToString() for e in events]

    def decode(i: int) -> tuple[Any, ...]:
        message = parcel_pb2.ParcelEvent()
        message.ParseFromString(wires[i])
        dims = message.dims
        return (
            message.weight_g,
            message.seq,
            message.intended_emit_ns,
            message.actual_emit_ns,
            message.encoder_tick,
            dims.length_mm,
            dims.width_mm,
            dims.height_mm,
            message.scan_confidence_permille,
            message.barcode,
        )

    return decode


def decoders(count: int) -> dict[str, Decode]:
    events = sample_parcels(count)
    return {
        UNPACK_FROM: unpack_decoder(encode_flat(events)),
        PARSE_FROM_STRING: parse_decoder(events),
    }


def new_ints(values: tuple[Any, ...]) -> int:
    """How many of the values are ints outside CPython's small-int cache: each is a new object."""
    return sum(
        1 for v in values if isinstance(v, int) and not _SMALL_INT_MIN <= v <= _SMALL_INT_MAX
    )


def observe_allocations(decode: Decode, count: int) -> dict[str, float]:
    """What decoding and reading every field creates, per parcel, over ``count`` parcels.

    The results are kept in a list, so nothing is freed while the counters are read.
    ``sys.getallocatedblocks`` counts the interpreter's small-object blocks (the tuple, the ints,
    the ``bytes`` or ``str`` of the barcode). A protobuf message itself lives in upb's own arena,
    outside that count, so the figure for ``parse-from-string`` is a lower bound of what it
    allocates; the int objects are the same in both paths.
    """
    gc.collect()
    gc.disable()
    try:
        before = sys.getallocatedblocks()
        kept = [decode(i) for i in range(count)]
        blocks = sys.getallocatedblocks() - before
    finally:
        gc.enable()
    return {
        "parcels": count,
        "blocks_per_parcel": blocks / count,
        "new_int_objects_per_parcel": sum(new_ints(v) for v in kept) / count,
        "fields_per_parcel": len(kept[0]),
    }


def time_decodes(decode: Decode, variant: str, count: int, rounds: int) -> Recorder:
    """Per-call time of ``rounds * count`` decodes, one sample each. The two clock reads around a
    call are inside every sample; they are the same for both variants."""
    recorder = Recorder(EXAMPLE, variant)
    clock = time.perf_counter_ns
    for _ in range(rounds):
        for i in range(count):
            start = clock()
            decode(i)
            recorder.record(clock() - start)
    return recorder
