package io.patterncatalyst.lowlat.gctails;

/**
 * The size of the tracker's heap workload. The live set is the rolling shift manifest plus the
 * in-flight parcels; the garbage is the scan history built for every parcel.
 *
 * @param rate parcels per second the line emits (sizes the in-flight window and the per-parcel
 *     share of the allocation rate)
 * @param liveSetBytes target size of the rolling manifest
 * @param entryBytes label bytes in one manifest entry
 * @param allocBytesPerSecond scan-history allocation rate; the heap sees this as garbage
 * @param inFlightMs how long a parcel stays between the scanner and the diverter
 * @param retainedSamples scan samples a parcel keeps while in flight (the rest is garbage at once)
 */
record Settings(long rate, long liveSetBytes, int entryBytes, long allocBytesPerSecond, int inFlightMs,
        int retainedSamples) {

    /** Payload of one raw scan sample. */
    static final int SAMPLE_BYTES = 512;

    /** Per-entry overhead beyond the label: entry, barcode String and its array, label header. */
    static final int ENTRY_OVERHEAD_BYTES = 160;

    /** Approximate heap size of one sample: the record plus the {@code byte[]} header and payload. */
    static final int SAMPLE_HEAP_BYTES = SAMPLE_BYTES + 48;

    Settings {
        if (rate < 1 || liveSetBytes < 1 || entryBytes < 1 || allocBytesPerSecond < 1 || inFlightMs < 1
                || retainedSamples < 0) {
            throw new IllegalArgumentException("every setting must be positive: " + this);
        }
    }

    static Settings defaults() {
        return new Settings(10_000, 1_750L << 20, 4096, 400L << 20, 480, 8);
    }

    /** Entries in the rolling manifest ring. */
    int manifestEntries() {
        return (int) Math.max(1, liveSetBytes / (entryBytes + ENTRY_OVERHEAD_BYTES));
    }

    /** Parcels that fit between the scanner and the diverter. */
    int inFlightParcels() {
        return (int) Math.max(1, rate * inFlightMs / 1000);
    }

    /** Samples built for each parcel so that {@code rate} parcels per second allocate the target. */
    int samplesPerParcel() {
        long bytesPerParcel = allocBytesPerSecond / rate;
        return (int) Math.max(1, (bytesPerParcel + SAMPLE_HEAP_BYTES - 1) / SAMPLE_HEAP_BYTES);
    }
}
