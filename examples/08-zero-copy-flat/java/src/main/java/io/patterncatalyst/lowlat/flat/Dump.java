package io.patterncatalyst.lowlat.flat;

import io.patterncatalyst.lowlat.line.Decoder;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import tools.jackson.databind.json.JsonMapper;

/**
 * Decodes a file of back-to-back {@code parcel-v1} records (the golden files) and prints them in
 * the shape of {@code golden-seedN.json}: 16 and 32-bit fields as numbers, 64-bit fields as decimal
 * strings. {@code verify.sh} compares this output with the C++ and Python tools and with the
 * committed JSON, so the three readers are checked against each other, not only against a file.
 */
final class Dump {

    private Dump() {
    }

    static int run(List<String> args) throws IOException {
        if (args.size() != 1) {
            System.err.println("usage: Main dump FILE");
            return 2;
        }
        byte[] bytes = Files.readAllBytes(Path.of(args.getFirst()));
        if (bytes.length % ParcelLayout.SIZE != 0) {
            System.err.println("dump: " + bytes.length + " bytes is not a whole number of "
                    + ParcelLayout.SIZE + "-byte records");
            return 1;
        }
        // The same path the receive loop takes: one direct buffer, position and limit select a record.
        ByteBuffer buffer = ByteBuffer.allocateDirect(bytes.length).put(bytes);
        FlatDecoder decoder = new FlatDecoder();
        List<Map<String, Object>> records = new ArrayList<>();
        try {
            for (int at = 0; at < bytes.length; at += ParcelLayout.SIZE) {
                buffer.clear().position(at).limit(at + ParcelLayout.SIZE);
                records.add(describe(decoder.decode(buffer)));
            }
        } catch (Decoder.MalformedDatagramException e) {
            System.err.println("dump: " + e.getMessage());
            return 1;
        }
        System.out.println(JsonMapper.builder().build().writerWithDefaultPrettyPrinter()
                .writeValueAsString(Map.of("records", records)));
        return 0;
    }

    private static Map<String, Object> describe(FlatView view) {
        Map<String, Object> record = new LinkedHashMap<>();
        record.put("schema_id", view.schemaId());
        record.put("version", view.version());
        record.put("weight_g", view.weightG());
        record.put("seq", Long.toUnsignedString(view.seq()));
        record.put("intended_emit_ns", Long.toString(view.intendedEmitNs()));
        record.put("actual_emit_ns", Long.toString(view.actualEmitNs()));
        record.put("encoder_tick", Long.toUnsignedString(view.encoderTick()));
        record.put("length_mm", view.lengthMm());
        record.put("width_mm", view.widthMm());
        record.put("height_mm", view.heightMm());
        record.put("scan_confidence_permille", view.scanConfidencePermille());
        record.put("barcode", view.barcode());
        return record;
    }
}
