package io.patterncatalyst.lowlat.ch12;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.http.HttpClient;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.Executors;
import org.junit.jupiter.api.Test;

class OpenLoopClientTest {

    @Test
    void theScheduleIsOpenLoopAndEveryRequestIsAnswered() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.createContext("/plan/test/", exchange -> {
            byte[] body = "lane=1".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, body.length);
            exchange.getResponseBody().write(body);
            exchange.close();
        });
        server.start();
        try (HttpClient client = HttpClient.newHttpClient()) {
            String url = "http://127.0.0.1:" + server.getAddress().getPort() + "/plan/test/";
            OpenLoopClient.Result r = OpenLoopClient.run(client, url, "test", 400, 1);
            assertEquals(400, r.sent());
            assertEquals(400, r.completed());
            assertEquals(0, r.errors());
            assertEquals(400, r.latency().histogram().getTotalCount());
            assertEquals(400, r.lateness().histogram().getTotalCount());
            assertTrue(r.maxInFlight() >= 1);
        } finally {
            server.stop(0);
        }
    }

    @Test
    void anErrorStatusIsCountedAndNotRecordedAsLatency() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
        server.createContext("/plan/bad/", exchange -> {
            exchange.sendResponseHeaders(500, -1);
            exchange.close();
        });
        server.start();
        try (HttpClient client = HttpClient.newHttpClient()) {
            OpenLoopClient.Result r = OpenLoopClient.run(client, "http://127.0.0.1:" + server.getAddress().getPort() + "/plan/bad/", "bad", 100, 1);
            assertEquals(100, r.errors());
            assertEquals(0, r.completed());
        } finally {
            server.stop(0);
        }
    }

    @Test
    void theStatsLinesBecomeCounters() {
        Map<String, Long> m = OpenLoopClient.parseStats("service_requests 12\ncarrier_threads 3\nnote text here\nbad x\n");
        assertEquals(Map.of("service_requests", 12L, "carrier_threads", 3L), m);
    }

    @Test
    void theSyntheticSsccIsEighteenDigits() {
        for (long i : new long[] {0, 1, 999_999_999L, 1_000_000_007L}) {
            String s = OpenLoopClient.sscc(i);
            assertEquals(18, s.length(), s);
            assertTrue(s.chars().allMatch(Character::isDigit), s);
        }
    }
}
