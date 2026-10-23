package io.patterncatalyst.lowlat.flat;

import io.patterncatalyst.lowlat.line.Decoder;
import io.patterncatalyst.lowlat.line.Lanes;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.nio.ByteBuffer;
import java.util.concurrent.TimeUnit;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OperationsPerInvocation;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.Warmup;

/**
 * Decode one datagram and read the fields the line needs (seq, weight, length, lane), from the
 * same kind of memory the receive loop uses: one direct buffer whose position and limit select the
 * datagram. {@code protobufDecode} runs the receiver's default {@code Decoder} and reads the
 * fields from the message; {@code flatFfm} runs {@link FlatDecoder} and reads the same fields from
 * the reused {@link FlatView}.
 *
 * <p>SampleTime mode reports percentiles of the time per decoded parcel (one invocation decodes
 * {@value #BATCH} parcels and JMH divides by {@code @OperationsPerInvocation}, as in Ch4); the
 * {@code gc} profiler reports bytes allocated per parcel ({@code gc.alloc.rate.norm}). Both
 * methods run in one JMH invocation.
 */
@BenchmarkMode(Mode.SampleTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Warmup(iterations = 4, time = 500, timeUnit = TimeUnit.MILLISECONDS)
@Measurement(iterations = 5, time = 500, timeUnit = TimeUnit.MILLISECONDS)
@Fork(value = 2, jvmArgsAppend = "--enable-native-access=ALL-UNNAMED")
@State(Scope.Thread)
public class DecodeBenchmark {

    static final int BATCH = 1024;

    private SampleWire wire;
    private Decoder<ParcelEvent> protobuf;
    private FlatDecoder flat;

    @Setup
    public void setup() {
        wire = new SampleWire(BATCH, 2026);
        protobuf = Decoder.protobuf();
        flat = new FlatDecoder();
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    public long protobufDecode() throws Decoder.MalformedDatagramException {
        ByteBuffer buffer = wire.protobuf();
        int stride = wire.protobufStride();
        long checksum = 0;
        for (int i = 0; i < BATCH; i++) {
            int at = i * stride;
            buffer.clear().position(at).limit(at + wire.protobufLength(i));
            ParcelEvent event = protobuf.decode(buffer);
            checksum += event.getSeq() + event.getWeightG() + event.getDims().getLengthMm()
                    + Lanes.laneOf(event.getBarcode());
        }
        return checksum;
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    public long flatFfm() throws Decoder.MalformedDatagramException {
        ByteBuffer buffer = wire.flat();
        int size = wire.flatLength();
        long checksum = 0;
        for (int i = 0; i < BATCH; i++) {
            int at = i * size;
            buffer.clear().position(at).limit(at + size);
            FlatView view = flat.decode(buffer);
            checksum += view.seq() + view.weightG() + view.lengthMm() + view.lane();
        }
        return checksum;
    }
}
