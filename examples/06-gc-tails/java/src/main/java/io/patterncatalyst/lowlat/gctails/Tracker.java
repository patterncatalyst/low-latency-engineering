package io.patterncatalyst.lowlat.gctails;

import io.patterncatalyst.lowlat.line.Lanes;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The in-flight parcel tracker with a heap that looks like a shift in progress.
 *
 * <p>Three kinds of data, three lifetimes:
 *
 * <ul>
 *   <li>The <b>shift manifest</b> is a ring of entries, one per parcel scanned this shift. It is
 *       full before the first parcel arrives and each new parcel overwrites the oldest entry, so
 *       the live set stays constant while old entries die in the old generation.
 *   <li>The <b>in-flight table</b> holds a parcel from the scanner to the diverter. It is the
 *       idiomatic {@link LinkedHashMap} with {@code removeEldestEntry}: the eldest parcel is
 *       diverted when a new one is scanned.
 *   <li>The <b>scan history</b> is built for each parcel from the raw sensor reads and reduced to
 *       a checksum. Most of it is garbage at once; this is the allocation rate the collector must
 *       keep up with.
 * </ul>
 *
 * <p>Single-threaded: the receive thread is the only caller after {@link #populate()}.
 */
final class Tracker {

    /** One raw sensor read. */
    record ScanSample(long atNs, int sensor, byte[] raw) { }

    /** A manifest line: what the shift knows about one parcel. */
    record ManifestEntry(String barcode, long seq, int lane, int weightG, byte[] label) { }

    /** A parcel between the scanner and the diverter. */
    record ParcelState(long seq, int lane, long checksum, ScanSample[] retained) { }

    /** The parcels between scan and divert; the eldest leaves when the belt is full. */
    private static final class InFlight extends LinkedHashMap<String, ParcelState> {
        private static final long serialVersionUID = 1L;

        private final int capacity;

        InFlight(int capacity) {
            super(capacity * 2, 0.75f);
            this.capacity = capacity;
        }

        @Override
        protected boolean removeEldestEntry(Map.Entry<String, ParcelState> eldest) {
            return size() > capacity;
        }
    }

    private final Settings settings;
    private final ManifestEntry[] manifest;
    private final InFlight inFlight;
    private final int samplesPerParcel;
    private long cursor;
    private long sink; // keeps the checksum, and so the history, observable

    Tracker(Settings settings) {
        this.settings = settings;
        this.manifest = new ManifestEntry[settings.manifestEntries()];
        this.inFlight = new InFlight(settings.inFlightParcels());
        this.samplesPerParcel = settings.samplesPerParcel();
    }

    /** Fills the manifest, so the run starts with the live set a shift in progress has. */
    void populate() {
        for (int i = 0; i < manifest.length; i++) {
            manifest[i] = entry(syntheticBarcode(i), i, i & 7, 1500 + (i & 1023));
        }
    }

    /**
     * Handles one parcel: lane lookup, scan history, manifest line, in-flight table.
     *
     * @return the lane
     */
    int track(String barcode, long seq, int weightG) {
        int lane = Lanes.laneOf(barcode);
        ScanSample[] history = scan(seq);
        long checksum = checksum(history);
        manifest[(int) (cursor++ % manifest.length)] = entry(barcode, seq, lane, weightG);
        int keep = Math.min(settings.retainedSamples(), history.length);
        inFlight.put(barcode, new ParcelState(seq, lane, checksum, Arrays.copyOf(history, keep)));
        sink += checksum;
        return lane;
    }

    int manifestEntries() {
        return manifest.length;
    }

    int samplesPerParcel() {
        return samplesPerParcel;
    }

    int inFlightSize() {
        return inFlight.size();
    }

    long sink() {
        return sink;
    }

    private ManifestEntry entry(String barcode, long seq, int lane, int weightG) {
        return new ManifestEntry(barcode, seq, lane, weightG, new byte[settings.entryBytes()]);
    }

    private ScanSample[] scan(long seq) {
        ScanSample[] samples = new ScanSample[samplesPerParcel];
        for (int i = 0; i < samples.length; i++) {
            byte[] raw = new byte[Settings.SAMPLE_BYTES];
            raw[0] = (byte) (seq + i);
            raw[raw.length - 1] = (byte) (seq >>> 8);
            samples[i] = new ScanSample(seq * 31 + i, i, raw);
        }
        return samples;
    }

    private static long checksum(ScanSample[] samples) {
        long sum = 0;
        for (ScanSample s : samples) {
            sum += s.atNs() + s.raw()[0] + s.raw()[s.raw().length - 1];
        }
        return sum;
    }

    /** An 18-character numeric string in the SSCC-18 shape: extension, prefix, 9-character serial, check. */
    static String syntheticBarcode(long n) {
        return "%08d%09d%d".formatted(0, Math.floorMod(n, 1_000_000_000L), 0);
    }
}
