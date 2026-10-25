package io.patterncatalyst.lowlat.ch15;

import java.util.BitSet;

/** The kernel's cpulist notation ("0-1,3"), as used by isolcpus=, /sys/devices/system/cpu/isolated and taskset -c. */
public final class CpuLists {

    private CpuLists() {
    }

    /** Parses "2-3", "0,2-3,7" or "" (no CPUs). A malformed item throws IllegalArgumentException. */
    public static BitSet parse(String list) {
        BitSet cpus = new BitSet();
        String text = list.strip();
        if (text.isEmpty()) {
            return cpus;
        }
        for (String item : text.split(",")) {
            String[] range = item.split("-", 2);
            try {
                int lo = Integer.parseInt(range[0].strip());
                int hi = range.length == 2 ? Integer.parseInt(range[1].strip()) : lo;
                if (lo < 0 || hi < lo) {
                    throw new IllegalArgumentException("bad CPU range '" + item + "' in '" + list + "'");
                }
                cpus.set(lo, hi + 1);
            } catch (NumberFormatException e) {
                throw new IllegalArgumentException("bad CPU list item '" + item + "' in '" + list + "'", e);
            }
        }
        return cpus;
    }

    /** The inverse of {@link #parse}: "0,2-3,7". */
    public static String format(BitSet cpus) {
        StringBuilder out = new StringBuilder();
        for (int lo = cpus.nextSetBit(0); lo >= 0; lo = cpus.nextSetBit(lo)) {
            int end = cpus.nextClearBit(lo);
            if (!out.isEmpty()) {
                out.append(',');
            }
            out.append(lo);
            if (end - 1 > lo) {
                out.append('-').append(end - 1);
            }
            lo = end;
        }
        return out.toString();
    }
}
