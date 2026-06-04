package visioncraft.bridge.mock;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import visioncraft.bridge.AppleNativeBridge;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.EOFException;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Arrays;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Headless VisionCraft host for M1 validation without macOS or Vision Pro.
 * Speaks bridge protocol v1 on TCP.
 */
public final class MockVisionCraftHost implements AutoCloseable {

    /** Max RGBA payload per eye (16 MiB). */
    public static final int MAX_EYE_BYTES = 16 * 1024 * 1024;

    private final int port;
    private final AtomicBoolean running = new AtomicBoolean(false);
    private ServerSocket serverSocket;
    private Thread acceptThread;
    private final MockHostStats stats = new MockHostStats();
    private final Set<Socket> clients = ConcurrentHashMap.newKeySet();
    private final String dumpDir;
    private final AtomicInteger dumpRemaining;

    public MockVisionCraftHost(int port) {
        this(port, null, 0);
    }

    /** {@code dumpDir != null} dumps the first {@code dumpFrames} received frames as per-eye PNGs. */
    public MockVisionCraftHost(int port, String dumpDir, int dumpFrames) {
        this.port = port;
        this.dumpDir = dumpDir;
        this.dumpRemaining = new AtomicInteger(dumpFrames);
    }

    /** Binds to an ephemeral port; call {@link #getBoundPort()} after {@link #start()}. */
    public static MockVisionCraftHost bindEphemeral() throws IOException {
        ServerSocket ss = new ServerSocket(0);
        int p = ss.getLocalPort();
        ss.close();
        return new MockVisionCraftHost(p);
    }

    public static void main(String[] args) throws Exception {
        int port = AppleNativeBridge.DEFAULT_PORT;
        String dumpDir = null;
        int dumpFrames = 0;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--dump-dir" -> dumpDir = args[++i];
                case "--dump-frames" -> dumpFrames = Integer.parseInt(args[++i]);
                default -> {
                    if (args[i].matches("\\d+")) {
                        port = Integer.parseInt(args[i]);
                    }
                }
            }
        }
        if (dumpDir != null && dumpFrames <= 0) {
            dumpFrames = 4;
        }
        try (MockVisionCraftHost host = new MockVisionCraftHost(port, dumpDir, dumpFrames)) {
            host.start();
            System.out.println("MockVisionCraftHost listening on " + host.getBoundPort());
            if (dumpDir != null) {
                System.out.println("MockVisionCraftHost dumping first " + dumpFrames
                    + " frames to " + dumpDir);
            }
            Thread.currentThread().join();
        }
    }

    public void start() throws IOException {
        if (running.getAndSet(true)) {
            return;
        }
        serverSocket = new ServerSocket();
        serverSocket.bind(new InetSocketAddress("127.0.0.1", port));
        acceptThread = new Thread(this::acceptLoop, "mock-visioncraft-accept");
        acceptThread.setDaemon(true);
        acceptThread.start();
    }

    public int getBoundPort() {
        return serverSocket != null ? serverSocket.getLocalPort() : port;
    }

    private void acceptLoop() {
        while (running.get()) {
            try {
                Socket client = serverSocket.accept();
                client.setTcpNoDelay(true);
                Thread t = new Thread(() -> handleClient(client), "mock-visioncraft-client");
                t.setDaemon(true);
                t.start();
            } catch (IOException e) {
                if (running.get()) {
                    System.err.println("MockVisionCraftHost accept: " + e.getMessage());
                }
            }
        }
    }

    private void handleClient(Socket client) {
        clients.add(client);
        try (
            Socket c = client;
            InputStream in = new BufferedInputStream(c.getInputStream());
            BufferedOutputStream out = new BufferedOutputStream(c.getOutputStream())
        ) {
            sendJson(out, sessionJson("paused"));
            sendJson(out, VIEW_CONFIG_JSON);
            try {
                Thread.sleep(25);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
            sendJson(out, sessionJson("ready"));
            sendJson(out, handJson());
            sendJson(out, controllerJson());
            AtomicInteger recenterCounter = new AtomicInteger(0);
            AtomicBoolean poseRunning = new AtomicBoolean(true);
            Thread poseThread = new Thread(() -> poseLoop(out, recenterCounter, poseRunning), "mock-pose");
            poseThread.setDaemon(true);
            poseThread.start();

            try {
                readLoop(in, out, recenterCounter);
            } finally {
                poseRunning.set(false);
                poseThread.interrupt();
            }
        } catch (IOException e) {
            stats.connectionsClosed.incrementAndGet();
        } finally {
            clients.remove(client);
        }
    }

    /**
     * Dump the first {@code dumpFrames} received frames as per-eye PNGs (no flip; the test-pattern
     * sender writes top-down, so PNGs come out upright). Useful for offline bridge/packing checks.
     */
    private void maybeDumpFrame(JsonObject frame, byte[] payload, int leftLen, int rightLen) {
        if (dumpDir == null || dumpRemaining.get() <= 0 || dumpRemaining.getAndDecrement() <= 0) {
            return;
        }
        try {
            JsonObject left = frame.getAsJsonObject("left");
            JsonObject right = frame.getAsJsonObject("right");
            int lw = left.get("width").getAsInt();
            int lh = left.get("height").getAsInt();
            int rw = right.get("width").getAsInt();
            int rh = right.get("height").getAsInt();
            File dir = new File(dumpDir);
            if (!dir.exists() && !dir.mkdirs()) {
                System.err.println("MockVisionCraftHost could not create dump dir " + dir);
                return;
            }
            long id = frame.get("frame_id").getAsLong();
            String stem = String.format("frame_%08d", id);
            byte[] leftBytes = Arrays.copyOfRange(payload, 0, leftLen);
            byte[] rightBytes = Arrays.copyOfRange(payload, leftLen, leftLen + rightLen);
            writePng(leftBytes, lw, lh, new File(dir, stem + "_left.png"));
            writePng(rightBytes, rw, rh, new File(dir, stem + "_right.png"));
            System.out.println("MockVisionCraftHost dumped frame " + id + " to " + dir.getAbsolutePath());
        } catch (Exception e) {
            System.err.println("MockVisionCraftHost dump failed: " + e.getMessage());
        }
    }

    private static void writePng(byte[] rgba, int width, int height, File out) throws IOException {
        if (rgba.length < width * height * 4) {
            return;
        }
        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        int rowBytes = width * 4;
        for (int y = 0; y < height; y++) {
            int row = y * rowBytes;
            for (int x = 0; x < width; x++) {
                int i = row + x * 4;
                int r = rgba[i] & 0xFF;
                int g = rgba[i + 1] & 0xFF;
                int b = rgba[i + 2] & 0xFF;
                int a = rgba[i + 3] & 0xFF;
                img.setRGB(x, y, (a << 24) | (r << 16) | (g << 8) | b);
            }
        }
        ImageIO.write(img, "png", out);
    }

    private void readLoop(InputStream in, BufferedOutputStream out, AtomicInteger recenterCounter)
        throws IOException
    {
        StringBuilder line = new StringBuilder();
        JsonObject pendingFrame = null;
        int pendingBinary = 0;

        while (running.get()) {
            if (pendingFrame != null) {
                int leftLen = pendingFrame.getAsJsonObject("left").get("byte_length").getAsInt();
                int rightLen = pendingFrame.getAsJsonObject("right").get("byte_length").getAsInt();
                if (leftLen < 0 || rightLen < 0 || leftLen > MAX_EYE_BYTES || rightLen > MAX_EYE_BYTES) {
                    throw new IOException("Invalid eye byte_length");
                }
                pendingBinary = leftLen + rightLen;
                byte[] payload = in.readNBytes(pendingBinary);
                if (payload.length != pendingBinary) {
                    throw new EOFException("Short frame payload");
                }
                stats.framesReceived.incrementAndGet();
                stats.lastFrameId = pendingFrame.get("frame_id").getAsLong();
                stats.lastLeftBytes = leftLen;
                stats.lastRightBytes = rightLen;
                maybeDumpFrame(pendingFrame, payload, leftLen, rightLen);
                pendingFrame = null;
                pendingBinary = 0;
                continue;
            }

            int b = in.read();
            if (b < 0) {
                return;
            }
            if (b == '\n') {
                String text = line.toString();
                line.setLength(0);
                if (text.isBlank()) {
                    continue;
                }
                JsonObject obj = JsonParser.parseString(text).getAsJsonObject();
                String type = obj.get("type").getAsString();
                if ("frame".equals(type)) {
                    pendingFrame = obj;
                } else {
                    handleControl(type, obj, out, recenterCounter);
                }
            } else {
                line.append((char) b);
                if (line.length() > 65536) {
                    throw new IOException("JSON line too long");
                }
            }
        }
    }

    private void handleControl(String type, JsonObject obj, BufferedOutputStream out, AtomicInteger recenterCounter)
        throws IOException
    {
        switch (type) {
            case "recenter" -> {
                int c = recenterCounter.incrementAndGet();
                sendJson(out, String.format(
                    "{\"type\":\"recenter\",\"version\":1,\"recenter_counter\":%d}", c));
            }
            case "ping" -> {
                long ts = obj.get("timestamp_ns").getAsLong();
                sendJson(out, String.format(
                    "{\"type\":\"pong\",\"version\":1,\"timestamp_ns\":%d}", ts));
            }
            case "haptic" -> {
                stats.hapticsReceived.incrementAndGet();
                stats.lastHapticHand = obj.has("hand") ? obj.get("hand").getAsString() : "";
                stats.lastHapticDurationSeconds = obj.has("duration_s") ? obj.get("duration_s").getAsFloat() : 0f;
                stats.lastHapticFrequencyHz = obj.has("frequency_hz") ? obj.get("frequency_hz").getAsFloat() : 0f;
                stats.lastHapticAmplitude = obj.has("amplitude") ? obj.get("amplitude").getAsFloat() : 0f;
            }
            default -> { /* ignore */ }
        }
    }

    private void poseLoop(BufferedOutputStream out, AtomicInteger recenterCounter, AtomicBoolean running) {
        float yaw = 0f;
        int poseTicks = 0;
        while (running.get()) {
            try {
                yaw += 0.002f;
                poseTicks += 1;
                if (poseTicks % 120 == 0) {
                    synchronized (out) {
                        sendJson(out, handJson());
                        sendJson(out, controllerJson());
                    }
                }
                float half = yaw / 2f;
                float qy = (float) Math.sin(half);
                float qw = (float) Math.cos(half);
                long ts = System.nanoTime();
                String json = String.format(
                    "{\"type\":\"pose\",\"version\":1,\"timestamp_ns\":%d," +
                        "\"position_m\":[0.0,1.65,0.0],\"orientation_xyzw\":[0.0,%s,0.0,%s]," +
                        "\"tracking_state\":\"valid\",\"recenter_counter\":%d}",
                    ts, qy, qw, recenterCounter.get()
                );
                synchronized (out) {
                    sendJson(out, json);
                }
                stats.posesSent.incrementAndGet();
                Thread.sleep(14);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            } catch (IOException e) {
                break;
            }
        }
    }

    private static void sendJson(BufferedOutputStream out, String json) throws IOException {
        if (!json.endsWith("\n")) {
            json = json + "\n";
        }
        synchronized (out) {
            out.write(json.getBytes(StandardCharsets.UTF_8));
            out.flush();
        }
    }

    private static String sessionJson(String state) {
        return String.format("{\"type\":\"session\",\"version\":1,\"state\":\"%s\"}", state);
    }

    /**
     * Asymmetric per-eye frustum (nasal edge tangent smaller than temporal). Defaults to a
     * representative AVP-like config, but every field can be overridden via environment so the
     * EXACT device {@code view_config} captured from one live session (see a capture bundle's
     * {@code header.json}) can be replayed headless:
     * <ul>
     *   <li>{@code VISIONCRAFT_VIEW_IPD_M} (default {@code 0.063})</li>
     *   <li>{@code VISIONCRAFT_VIEW_TANGENTS_LEFT} / {@code _RIGHT} — comma {@code L,R,U,D}
     *       (defaults {@code 1.21,0.93,1.02,1.02} / {@code 0.93,1.21,1.02,1.02})</li>
     *   <li>{@code VISIONCRAFT_VIEW_EYE_WIDTH} / {@code _HEIGHT} (defaults {@code 1888}/{@code 1824})</li>
     * </ul>
     */
    private static final String VIEW_CONFIG_JSON = buildViewConfigJson();

    private static String env(String key, String fallback) {
        String v = System.getenv(key);
        return (v == null || v.isBlank()) ? fallback : v.trim();
    }

    private static String buildViewConfigJson() {
        String ipd = env("VISIONCRAFT_VIEW_IPD_M", "0.063");
        String left = env("VISIONCRAFT_VIEW_TANGENTS_LEFT", "1.21,0.93,1.02,1.02");
        String right = env("VISIONCRAFT_VIEW_TANGENTS_RIGHT", "0.93,1.21,1.02,1.02");
        String w = env("VISIONCRAFT_VIEW_EYE_WIDTH", "1888");
        String h = env("VISIONCRAFT_VIEW_EYE_HEIGHT", "1824");
        return "{\"type\":\"view_config\",\"version\":1,\"ipd_m\":" + ipd + ","
            + "\"views\":["
            + "{\"index\":0,\"tangents\":[" + left + "],\"width\":" + w + ",\"height\":" + h + "},"
            + "{\"index\":1,\"tangents\":[" + right + "],\"width\":" + w + ",\"height\":" + h + "}"
            + "]}";
    }

    /** Right hand fully pinched, left hand open — exercises both the pinch and idle paths. */
    private static String handJson() {
        long timestampNs = System.currentTimeMillis() * 1_000_000L;
        return "{\"type\":\"hand\",\"version\":1,\"timestamp_ns\":" + timestampNs + ",\"hands\":[" +
            "{\"chirality\":\"left\",\"tracked\":true,\"position_m\":[-0.2,1.3,-0.3]," +
            "\"orientation_xyzw\":[0.0,0.0,0.0,1.0],\"pinch\":0.05}," +
            "{\"chirality\":\"right\",\"tracked\":true,\"position_m\":[0.2,1.3,-0.3]," +
            "\"orientation_xyzw\":[0.0,0.0,0.0,1.0],\"pinch\":0.92}" +
            "]}";
    }

    private static String controllerJson() {
        long timestampNs = System.currentTimeMillis() * 1_000_000L;
        return "{\"type\":\"controller\",\"version\":1,\"timestamp_ns\":" + timestampNs + ",\"controllers\":[" +
            "{\"hand\":\"left\",\"tracked\":true,\"position_m\":[-0.2,1.3,-0.3]," +
            "\"orientation_xyzw\":[0.0,0.0,0.0,1.0]," +
            "\"buttons\":{\"x\":true,\"trigger_click\":false}," +
            "\"axes\":{\"thumbstick_x\":0.25,\"thumbstick_y\":-0.5,\"trigger\":0.1}}," +
            "{\"hand\":\"right\",\"tracked\":true,\"position_m\":[0.2,1.3,-0.3]," +
            "\"orientation_xyzw\":[0.0,0.0,0.0,1.0]," +
            "\"buttons\":{\"a\":true,\"trigger_click\":true}," +
            "\"axes\":{\"thumbstick_x\":0.75,\"thumbstick_y\":0.0,\"trigger\":1.0}}" +
            "]}";
    }

    public MockHostStats getStats() {
        return stats;
    }

    @Override
    public void close() {
        running.set(false);
        if (serverSocket != null) {
            try {
                serverSocket.close();
            } catch (IOException ignored) {
            }
        }
        for (Socket client : clients) {
            try {
                client.close();
            } catch (IOException ignored) {
            }
        }
        if (acceptThread != null) {
            acceptThread.interrupt();
        }
    }

    public static final class MockHostStats {
        public final AtomicLong framesReceived = new AtomicLong();
        public final AtomicLong posesSent = new AtomicLong();
        public final AtomicLong hapticsReceived = new AtomicLong();
        public final AtomicInteger connectionsClosed = new AtomicInteger();
        public volatile long lastFrameId;
        public volatile int lastLeftBytes;
        public volatile int lastRightBytes;
        public volatile String lastHapticHand = "";
        public volatile float lastHapticDurationSeconds;
        public volatile float lastHapticFrequencyHz;
        public volatile float lastHapticAmplitude;
    }
}
