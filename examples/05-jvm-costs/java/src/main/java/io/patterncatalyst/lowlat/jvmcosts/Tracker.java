package io.patterncatalyst.lowlat.jvmcosts;

import io.patterncatalyst.lowlat.line.v1.Dimensions;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.Map;

/**
 * The in-flight parcel tracker of the scan-to-divert path, light version (the full tracker is Part 3).
 *
 * <p>{@link #decide} is the pure decision: lane from the scan confidence, the dimensions and the weight,
 * and the belt position of the divert deadline. {@link #onParcel} adds the state: a barcode-keyed
 * {@link HashMap} of the parcels between the scanner and the diverter, expired by encoder tick.
 *
 * <p>Allocation is the subject. {@code decide} allocates one {@link DivertDecision} that the JIT removes
 * (scalar replacement) or keeps, depending on what the caller does with it; {@code onParcel} allocates the
 * barcode string, a map node and an entry per parcel, which no JIT removes.
 */
public final class Tracker {

    /** Lane for a parcel that cannot be routed (unreadable scan). */
    public static final int EXCEPTION_LANE = 0;
    /** Lane for an oversize or overweight parcel (manual chute). */
    public static final int OVERSIZE_LANE = 7;
    /** Sort lanes 1 to 6 are weight classes of 1 kg. */
    public static final int SORT_LANES = 6;
    /** Scanner to diverter: 1.2 m at 1,000 encoder pulses per metre, the simulator's defaults. */
    public static final long DIVERT_TICKS = 1_200;

    static final int MIN_CONFIDENCE_PERMILLE = 900;
    static final int OVERSIZE_MM = 1_000;
    static final int OVERSIZE_G = 30_000;
    static final int WEIGHT_CLASS_G = 1_000;

    private static final int RING = 8_192; // above the in-flight count at 1 kHz

    private record InFlight(long seq, int lane, long deadlineTick) {
    }

    private final Map<String, InFlight> inFlight = HashMap.newHashMap(RING);
    // Barcodes in arrival order, oldest first. Sized for RING elements, so it never grows. Barcodes
    // are unique among the parcels in flight (one physical label per parcel); a repeated barcode
    // would make expiry remove the newer parcel's map entry.
    private final ArrayDeque<String> arrivals = new ArrayDeque<>(RING);

    /** The decision for one parcel. Pure: no state, so a caller that only reads it lets the JIT drop the object. */
    public static DivertDecision decide(ParcelEvent event) {
        Dimensions dims = event.getDims();
        int longestMm = Math.max(dims.getLengthMm(), Math.max(dims.getWidthMm(), dims.getHeightMm()));
        int lane;
        if (event.getScanConfidencePermille() < MIN_CONFIDENCE_PERMILLE) {
            lane = EXCEPTION_LANE;
        } else if (longestMm > OVERSIZE_MM || event.getWeightG() > OVERSIZE_G) {
            lane = OVERSIZE_LANE;
        } else {
            lane = 1 + Math.min(SORT_LANES - 1, event.getWeightG() / WEIGHT_CLASS_G);
        }
        return new DivertDecision(lane, event.getEncoderTick() + DIVERT_TICKS);
    }

    /** Decide, then record the parcel as in flight until its deadline passes. */
    public DivertDecision onParcel(ParcelEvent event) {
        DivertDecision decision = decide(event);
        expire(event.getEncoderTick());
        if (arrivals.size() == RING) {
            evictOldest();
        }
        String barcode = event.getBarcode();
        inFlight.put(barcode, new InFlight(event.getSeq(), decision.lane(), decision.deadlineTick()));
        arrivals.offerLast(barcode);
        return decision;
    }

    /** Parcels between the scanner and the diverter right now. */
    public int inFlightCount() {
        return inFlight.size();
    }

    public boolean isInFlight(String barcode) {
        return inFlight.containsKey(barcode);
    }

    private void expire(long tick) {
        String barcode;
        while ((barcode = arrivals.peekFirst()) != null) {
            InFlight oldest = inFlight.get(barcode);
            if (oldest != null && oldest.deadlineTick() > tick) {
                return;
            }
            evictOldest();
        }
    }

    private void evictOldest() {
        inFlight.remove(arrivals.pollFirst());
    }
}
