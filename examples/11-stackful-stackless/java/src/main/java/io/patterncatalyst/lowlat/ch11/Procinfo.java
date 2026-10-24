package io.patterncatalyst.lowlat.ch11;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.OptionalLong;

/** Memory counters from /proc: the process's resident set, address space and page tables, and the system's kernel stacks. */
final class Procinfo {

    private Procinfo() {
    }

    /** A memory reading in kibibytes. */
    record Snapshot(long rssKib, long vmSizeKib, long pageTablesKib, long kernelStackKib, long heapUsedBytes) {
    }

    /** The value of {@code Key:   123 kB} in {@code file}, if present. */
    static OptionalLong kib(Path file, String key) {
        try {
            return parse(Files.readAllLines(file), key);
        } catch (IOException e) {
            throw new UncheckedIOException("cannot read " + file, e);
        }
    }

    static OptionalLong parse(List<String> lines, String key) {
        String prefix = key + ":";
        for (String line : lines) {
            if (line.startsWith(prefix)) {
                String[] words = line.substring(prefix.length()).strip().split("\\s+");
                return OptionalLong.of(Long.parseLong(words[0]));
            }
        }
        return OptionalLong.empty();
    }

    /** A reading; the heap figure is taken after a full collection so it is what the tasks keep alive. */
    static Snapshot snapshot(boolean collect) {
        if (collect) {
            System.gc();
        }
        Path status = Path.of("/proc/self/status");
        long heap = java.lang.management.ManagementFactory.getMemoryMXBean().getHeapMemoryUsage().getUsed();
        return new Snapshot(kib(status, "VmRSS").orElse(0), kib(status, "VmSize").orElse(0), kib(status, "VmPTE").orElse(0),
                kib(Path.of("/proc/meminfo"), "KernelStack").orElse(0), heap);
    }
}
