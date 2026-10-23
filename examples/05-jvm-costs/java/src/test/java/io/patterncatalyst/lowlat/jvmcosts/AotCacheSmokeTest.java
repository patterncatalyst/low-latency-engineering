package io.patterncatalyst.lowlat.jvmcosts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.jar.Attributes;
import java.util.jar.JarOutputStream;
import java.util.jar.Manifest;
import java.util.zip.ZipEntry;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * Smoke test for the ahead-of-time cache the {@code aot-cache} variant relies on (JEP 514 one-step
 * workflow): a child JVM trains a cache for a trivial main class, then a second child runs from it
 * with {@code -XX:AOTMode=on}, which refuses to start when the cache cannot be used.
 */
class AotCacheSmokeTest {

    /** The program the children run. Nested, so the test needs no extra source file. */
    public static final class Hello {
        private Hello() {}

        public static void main(String[] args) {
            System.out.println("hello " + args.length);
        }
    }

    @Test
    void trainedCacheLoadsWithAotModeOn(@TempDir Path dir) throws Exception {
        Path jar = packageHello(dir.resolve("hello.jar"));
        Path cache = dir.resolve("hello.aot");

        Result train = java("-XX:AOTCacheOutput=" + cache, "-cp", jar.toString(), Hello.class.getName());
        assertEquals(0, train.exit(), train.output());
        assertTrue(Files.size(cache) > 0, "training wrote the cache: " + train.output());

        Result run = java(
                "-XX:AOTCache=" + cache,
                "-XX:AOTMode=on",
                "-Xlog:aot",
                "-cp",
                jar.toString(),
                Hello.class.getName());
        assertEquals(0, run.exit(), run.output());
        assertTrue(run.output().contains("hello 0"), run.output());
    }

    /** CDS and AOT caches only cover classes from jars, so the nested class goes into one. */
    private static Path packageHello(Path jar) throws IOException {
        Manifest manifest = new Manifest();
        manifest.getMainAttributes().put(Attributes.Name.MANIFEST_VERSION, "1.0");
        String entry = Hello.class.getName().replace('.', '/') + ".class";
        try (OutputStream file = Files.newOutputStream(jar);
                JarOutputStream out = new JarOutputStream(file, manifest);
                InputStream in = AotCacheSmokeTest.class.getClassLoader().getResourceAsStream(entry)) {
            if (in == null) {
                throw new IOException("class file not found: " + entry);
            }
            out.putNextEntry(new ZipEntry(entry));
            in.transferTo(out);
            out.closeEntry();
        }
        return jar;
    }

    private record Result(int exit, String output) {}

    /** Runs the JVM that is running this test, merged stdout and stderr, with a generous timeout. */
    private static Result java(String... args) throws IOException, InterruptedException {
        List<String> command = new ArrayList<>();
        command.add(ProcessHandle.current().info().command().orElseThrow());
        command.addAll(List.of(args));
        Process process = new ProcessBuilder(command).redirectErrorStream(true).start();
        String output = new String(process.getInputStream().readAllBytes());
        if (!process.waitFor(60, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            throw new AssertionError("child JVM timed out: " + command + "\n" + output);
        }
        return new Result(process.exitValue(), output);
    }
}
