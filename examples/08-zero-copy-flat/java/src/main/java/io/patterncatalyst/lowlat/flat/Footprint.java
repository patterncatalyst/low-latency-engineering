package io.patterncatalyst.lowlat.flat;

import com.sun.management.HotSpotDiagnosticMXBean;
import io.patterncatalyst.lowlat.line.v1.ParcelEvent;
import java.lang.management.ManagementFactory;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.openjdk.jol.info.ClassLayout;
import org.openjdk.jol.info.GraphLayout;
import tools.jackson.databind.json.JsonMapper;

/**
 * Object footprint of the two table layouts, from JOL. Run it twice, with and without
 * {@code -XX:+UseCompactObjectHeaders} (a product flag in JDK 25, off by default): the flag shrinks
 * every object header from 12 to 8 bytes, which shows in {@link ParcelState} and in the object
 * table, and does nothing to the flat table. Observed, not asserted.
 */
final class Footprint {

    private static final int PARCELS = 100_000;

    private Footprint() {
    }

    static int run(List<String> args) {
        if (!args.isEmpty()) {
            System.err.println("usage: Main footprint");
            return 2;
        }
        boolean compact = Boolean.parseBoolean(
                ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class)
                        .getVMOption("UseCompactObjectHeaders").getValue());
        ParcelState[] states = new TableData(PARCELS, 2026).bySlot();
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("compact_object_headers", compact);
        out.put("parcels", PARCELS);
        out.put("parcel_state_instance_bytes", ClassLayout.parseClass(ParcelState.class).instanceSize());
        out.put("protobuf_parcel_event_instance_bytes", ClassLayout.parseClass(ParcelEvent.class).instanceSize());
        out.put("object_table_bytes", GraphLayout.parseInstance((Object) states).totalSize());
        try (FlatTable flat = FlatTable.copyOf(states)) {
            out.put("flat_table_bytes", flat.byteSize());
        }
        System.out.println(JsonMapper.builder().build().writerWithDefaultPrettyPrinter().writeValueAsString(out));
        return 0;
    }
}
