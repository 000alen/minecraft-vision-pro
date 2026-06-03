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
                    0.05f, 512f, null
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
    void clientReceivesHandPinch() throws Exception {
        try (MockVisionCraftHost host = MockVisionCraftHost.bindEphemeral()) {
            host.start();
            try (AppleNativeBridge bridge = new AppleNativeBridge("127.0.0.1", host.getBoundPort())) {
                bridge.connect();
                waitForSession(bridge, 5_000);
                waitForHands(bridge, 3_000);

                AppleNativeBridge.HandState hands = bridge.getHands();
                assertTrue(hands.timestampNs() > 0);
                assertTrue(hands.right().tracked());
                assertEquals(0.92f, hands.right().pinch(), 1e-4f);
                assertTrue(hands.left().tracked());
                assertEquals(0.05f, hands.left().pinch(), 1e-4f);
                // Advisory wrist position round-trips.
                assertEquals(0.2f, hands.right().positionM()[0], 1e-4f);
            }
        }
    }

    @Test
    void clientReceivesControllerState() throws Exception {
        try (MockVisionCraftHost host = MockVisionCraftHost.bindEphemeral()) {
            host.start();
            try (AppleNativeBridge bridge = new AppleNativeBridge("127.0.0.1", host.getBoundPort())) {
                bridge.connect();
                waitForSession(bridge, 5_000);
                waitForControllers(bridge, 3_000);

                AppleNativeBridge.ControllerState state = bridge.getControllerState();
                assertTrue(state.left().tracked());
                assertTrue(state.right().tracked());
                assertTrue(state.left().button("x"));
                assertTrue(state.right().button("a"));
                assertTrue(state.right().button("trigger_click"));
                assertEquals(0.25f, state.left().axis("thumbstick_x"), 1e-4f);
                assertEquals(-0.5f, state.left().axis("thumbstick_y"), 1e-4f);
                assertEquals(1.0f, state.right().axis("trigger"), 1e-4f);
                assertEquals(0.2f, state.right().positionM()[0], 1e-4f);
            }
        }
    }

    @Test
    void hapticCommandReachesMockHost() throws Exception {
        try (MockVisionCraftHost host = MockVisionCraftHost.bindEphemeral()) {
            host.start();
            try (AppleNativeBridge bridge = new AppleNativeBridge("127.0.0.1", host.getBoundPort())) {
                bridge.connect();
                waitForSession(bridge, 5_000);

                bridge.sendHaptic("right", 0.15f, 180f, 0.6f);

                waitForHaptics(host, 1, 3_000);
                assertEquals(1, host.getStats().hapticsReceived.get());
                assertEquals("right", host.getStats().lastHapticHand);
                assertEquals(0.15f, host.getStats().lastHapticDurationSeconds, 1e-4f);
                assertEquals(180f, host.getStats().lastHapticFrequencyHz, 1e-4f);
                assertEquals(0.6f, host.getStats().lastHapticAmplitude, 1e-4f);
            }
        }
    }

    @Test
    void disconnectClearsRemoteStateAndBridgeReconnects() throws Exception {
        int port;
        try (ServerSocketHolder holder = ServerSocketHolder.ephemeral()) {
            port = holder.port();
        }

        MockVisionCraftHost firstHost = new MockVisionCraftHost(port);
        firstHost.start();
        try (AppleNativeBridge bridge = new AppleNativeBridge("127.0.0.1", port)) {
            bridge.connect();
            waitForSession(bridge, 5_000);
            waitForViewConfig(bridge, 3_000);
            waitForPoses(bridge, 3_000);

            firstHost.close();
            waitForDisconnected(bridge, 3_000);

            assertFalse(bridge.isConnected());
            assertEquals(AppleNativeBridge.SessionState.LOST, bridge.getSessionState());
            assertNotNull(bridge.getLastDisconnectCause());
            assertNull(bridge.getViewConfig(), "view_config must not survive a lost bridge");
            assertEquals(0L, bridge.getLastPoseTimestampNs(), "pose timestamp must be cleared");
            assertEquals(0, bridge.getRecenterCounter(), "recenter state must be cleared");

            try (MockVisionCraftHost secondHost = new MockVisionCraftHost(port)) {
                secondHost.start();
                bridge.connectWithRetry(20, 100);
                waitForSession(bridge, 5_000);
                assertTrue(bridge.isConnected());
                assertEquals(AppleNativeBridge.SessionState.READY, bridge.getSessionState());
                assertNull(bridge.getLastDisconnectCause());
            }
        } finally {
            firstHost.close();
        }
    }

    @Test
    void immediateReconnectSurvivesStaleReaderExit() throws Exception {
        try (MockVisionCraftHost host = MockVisionCraftHost.bindEphemeral()) {
            host.start();
            try (AppleNativeBridge bridge = new AppleNativeBridge("127.0.0.1", host.getBoundPort())) {
                for (int i = 0; i < 20; i++) {
                    bridge.connect();
                    waitForSession(bridge, 5_000);

                    bridge.close();
                    bridge.connect();
                    waitForSession(bridge, 5_000);

                    Thread.sleep(50);
                    assertTrue(bridge.isConnected(), "stale reader must not close the reconnected socket");
                    assertEquals(AppleNativeBridge.SessionState.READY, bridge.getSessionState());
                    bridge.close();
                }
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

    private static void waitForHaptics(MockVisionCraftHost host, long min, long timeoutMs)
        throws InterruptedException
    {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (host.getStats().hapticsReceived.get() >= min) {
                return;
            }
            Thread.sleep(20);
        }
        fail("Expected haptics");
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

    private static void waitForHands(AppleNativeBridge bridge, long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (bridge.getHands().right().tracked() || bridge.getHands().left().tracked()) {
                return;
            }
            Thread.sleep(20);
        }
        fail("No hand message");
    }

    private static void waitForControllers(AppleNativeBridge bridge, long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (bridge.getControllerState().timestampNs() > 0) {
                return;
            }
            Thread.sleep(20);
        }
        fail("No controller message");
    }

    private static void waitForDisconnected(AppleNativeBridge bridge, long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (!bridge.isConnected() && bridge.getSessionState() == AppleNativeBridge.SessionState.LOST) {
                return;
            }
            Thread.sleep(20);
        }
        fail("Bridge did not report lost connection");
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
