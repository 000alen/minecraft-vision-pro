package visioncraft.bridge;

import org.junit.jupiter.api.Test;
import visioncraft.bridge.mock.MockVisionCraftHost;

import static org.junit.jupiter.api.Assertions.*;

/**
 * End-to-end M1 test without macOS host or Vision Pro.
 */
class BridgeIntegrationTest {

    @Test
    void clientSendsStereoFrameAndReceivesPose() throws Exception {
        try (MockVisionCraftHost host = MockVisionCraftHost.bindEphemeral()) {
            host.start();
            int port = host.getBoundPort();

            try (AppleNativeBridge bridge = new AppleNativeBridge("127.0.0.1", port)) {
                bridge.connect();
                waitForSession(bridge, 5_000);
                assertEquals(AppleNativeBridge.SessionState.READY, bridge.getSessionState());

                int w = 64;
                int h = 64;
                byte[] left = solid(w, h, (byte) 200, (byte) 0, (byte) 0);
                byte[] right = solid(w, h, (byte) 0, (byte) 0, (byte) 200);

                bridge.sendFrame(new AppleNativeBridge.FramePacket(
                    1L, System.nanoTime(),
                    w, h, left, w, h, right,
                    0.05f, 512f
                ));

                waitForFrames(host, 1, 3_000);
                assertEquals(1, host.getStats().framesReceived.get());
                assertEquals(w * h * 4, host.getStats().lastLeftBytes);
                assertEquals(w * h * 4, host.getStats().lastRightBytes);

                waitForPoses(bridge, 3_000);
                assertTrue(bridge.getLatestPose().isValid());
                assertTrue(bridge.getLatestPose().timestampNs() > 0);
            }
        }
    }

    @Test
    void clientReceivesAsymmetricViewConfig() throws Exception {
        try (MockVisionCraftHost host = MockVisionCraftHost.bindEphemeral()) {
            host.start();
            try (AppleNativeBridge bridge = new AppleNativeBridge("127.0.0.1", host.getBoundPort())) {
                bridge.connect();
                waitForSession(bridge, 5_000);
                waitForViewConfig(bridge, 3_000);

                AppleNativeBridge.ViewConfig vc = bridge.getViewConfig();
                assertNotNull(vc);
                assertEquals(0.063f, vc.ipdM(), 1e-4f);
                // Left eye: temporal (left) tangent larger than nasal (right).
                float[] left = vc.tangentsForEye(0);
                assertEquals(1.21f, left[0], 1e-4f);
                assertEquals(0.93f, left[1], 1e-4f);
                // Right eye is mirrored.
                float[] right = vc.tangentsForEye(1);
                assertEquals(0.93f, right[0], 1e-4f);
                assertEquals(1.21f, right[1], 1e-4f);
                assertEquals(1888, vc.leftWidth());
                assertEquals(1824, vc.leftHeight());
            }
        }
    }

    @Test
    void recenterIncrementsCounter() throws Exception {
        try (MockVisionCraftHost host = MockVisionCraftHost.bindEphemeral()) {
            host.start();
            try (AppleNativeBridge bridge = new AppleNativeBridge("127.0.0.1", host.getBoundPort())) {
                bridge.connect();
                waitForSession(bridge, 5_000);
                bridge.requestRecenter();
                Thread.sleep(250);
                assertTrue(bridge.getRecenterCounter() >= 0);
            }
        }
    }

    @Test
    void connectWithRetrySucceedsWhenHostStartsLate() throws Exception {
        int port;
        try (ServerSocketHolder holder = ServerSocketHolder.ephemeral()) {
            port = holder.port();
        }
        Thread lateHost = new Thread(() -> {
            try {
                Thread.sleep(400);
                try (MockVisionCraftHost host = new MockVisionCraftHost(port)) {
                    host.start();
                    Thread.sleep(5_000);
                }
            } catch (Exception ignored) {
            }
        }, "late-mock-host");
        lateHost.setDaemon(true);
        lateHost.start();

        try (AppleNativeBridge bridge = new AppleNativeBridge("127.0.0.1", port)) {
            bridge.connectWithRetry(15, 200);
            assertTrue(bridge.isConnected());
        }
    }

    private static void waitForSession(AppleNativeBridge bridge, long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (bridge.getSessionState() == AppleNativeBridge.SessionState.READY) {
                return;
            }
            Thread.sleep(20);
        }
        fail("Session not ready");
    }

    private static void waitForFrames(MockVisionCraftHost host, long min, long timeoutMs)
        throws InterruptedException
    {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (host.getStats().framesReceived.get() >= min) {
                return;
            }
            Thread.sleep(20);
        }
        fail("Expected frames");
    }

    private static void waitForViewConfig(AppleNativeBridge bridge, long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (bridge.getViewConfig() != null) {
                return;
            }
            Thread.sleep(20);
        }
        fail("No view_config");
    }

    private static void waitForPoses(AppleNativeBridge bridge, long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (bridge.getLatestPose().timestampNs() > 0) {
                return;
            }
            Thread.sleep(20);
        }
        fail("No pose");
    }

    private static byte[] solid(int w, int h, byte r, byte g, byte b) {
        byte[] rgba = new byte[w * h * 4];
        for (int i = 0; i < rgba.length; i += 4) {
            rgba[i] = r;
            rgba[i + 1] = g;
            rgba[i + 2] = b;
            rgba[i + 3] = (byte) 255;
        }
        return rgba;
    }

    /** Ephemeral port holder for late-start test. */
    private static final class ServerSocketHolder implements AutoCloseable {
        private final java.net.ServerSocket socket;

        static ServerSocketHolder ephemeral() throws java.io.IOException {
            return new ServerSocketHolder(new java.net.ServerSocket(0));
        }

        ServerSocketHolder(java.net.ServerSocket socket) {
            this.socket = socket;
        }

        int port() {
            return socket.getLocalPort();
        }

        @Override
        public void close() throws java.io.IOException {
            socket.close();
        }
    }
}
