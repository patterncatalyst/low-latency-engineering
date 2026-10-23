package io.patterncatalyst.lowlat.eliminating;

import java.lang.management.ManagementFactory;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.openjdk.jol.info.ClassLayout;
import org.openjdk.jol.info.GraphLayout;
import tools.jackson.databind.json.JsonMapper;

/**
 * Footprint with JOL (observed): the instance size of {@link ParcelState}, and the bytes behind a node-map tracker
 * and a flat tracker holding the same parcels. Prints one JSON object. JOL walks the object graph, so the
 * default is 100,000 parcels; the per-parcel figure scales to the hub.
 */
final class Footprint {

    private Footprint() {
    }

    static int run(List<String> args) {
        int parcels = args.isEmpty() ? 100_000 : Integer.parseInt(args.get(0));
        Keys keys = Keys.make(parcels, 2026);
        Scan scan = new Scan();
        NodeMapTracker node = new NodeMapTracker(parcels + parcels / 16);
        FlatMapTracker flat = FlatMapTracker.withColumns(parcels + parcels / 16);
        for (int i = 0; i < parcels; i++) {
            node.track(scan.of(keys, i));
            flat.track(scan.of(keys, i));
        }
        long nodeBytes = GraphLayout.parseInstance(node).totalSize();
        long flatBytes = GraphLayout.parseInstance(flat).totalSize();
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("parcels", parcels);
        out.put("compact_object_headers",
                ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-XX:+UseCompactObjectHeaders"));
        out.put("parcel_state_instance_bytes", ClassLayout.parseClass(ParcelState.class).instanceSize());
        out.put("barcode_string_bytes", GraphLayout.parseInstance((Object) keys.text(0)).totalSize());
        out.put("node_map_tracker_bytes", nodeBytes);
        out.put("node_map_bytes_per_parcel", nodeBytes / parcels);
        out.put("flat_map_tracker_bytes", flatBytes);
        out.put("flat_map_bytes_per_parcel", flatBytes / parcels);
        System.out.println(JsonMapper.builder().build().writerWithDefaultPrettyPrinter().writeValueAsString(out));
        return 0;
    }
}
