package visioncraft.bridge;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

/**
 * TCP client for VisionCraft bridge protocol v1.
 * Connects to VisionCraftHost on localhost:19735 by default.
 */
public final class AppleNativeBridge implements AutoCloseable {

    public static final int PROTOCOL_VERSION = 1;
    public static final String DEFAULT_HOST = "127.0.0.1";
    public static final int DEFAULT_PORT = 19735;

    private static final Gson GSON = new Gson();

    private final String host;
    private final int port;
    private final AtomicBoolean connected = new AtomicBoolean(false);
    private final AtomicLong lastPoseTimestampNs = new AtomicLong(0L);
    private final AtomicInteger recenterCounter = new AtomicInteger(0);

    private volatile Pose latestPose = Pose.identity();
    private volatile SessionState sessionState = SessionState.CLOSED;

    private Socket socket;
    private BufferedOutputStream out;
    private Thread readerThread;

    public AppleNativeBridge() {
        this(BridgeSettings.host(), BridgeSettings.port());
    }

    public AppleNativeBridge(String host, int port) {
        this.host = host;
        this.port = port;
    }

    public synchronized void connect() throws IOException {
        connectInternal();
    }

    /** Connect with retries while VisionCraftHost is starting. */
    public synchronized void connectWithRetry(int attempts, long delayMs) throws IOException {
        IOException last = null;
        for (int i = 0; i < attempts; i++) {
            try {
                connectInternal();
                return;
            } catch (IOException e) {
                last = e;
                close();
                try {
                    Thread.sleep(delayMs);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    throw new IOException("Interrupted while connecting", ie);
                }
            }
        }
        throw last != null ? last : new IOException("Failed to connect to VisionCraft host");
    }

    private void connectInternal() throws IOException {
        if (connected.get()) {
            return;
        }
        socket = new Socket();
        socket.connect(new InetSocketAddress(host, port), 5000);
        socket.setTcpNoDelay(true);
        InputStream in = new BufferedInputStream(socket.getInputStream());
        out = new BufferedOutputStream(socket.getOutputStream());
        connected.set(true);
        sessionState = SessionState.CLOSED;
        readerThread = new Thread(() -> readLoop(in), "visioncraft-bridge-reader");
        readerThread.setDaemon(true);
        readerThread.start();
    }

    private void readLoop(InputStream in) {
        StringBuilder line = new StringBuilder();
        try {
            int b;
            while (connected.get() && (b = in.read()) != -1) {
                if (b == '\n') {
                    handleLine(line.toString());
                    line.setLength(0);
                } else {
                    line.append((char) b);
                }
            }
        } catch (IOException e) {
            if (connected.get()) {
                sessionState = SessionState.LOST;
            }
        } finally {
            connected.set(false);
            sessionState = SessionState.CLOSED;
        }
    }

    private void handleLine(String json) {
        if (json.isEmpty()) {
            return;
        }
        final JsonObject obj;
        final String type;
        final int version;
        try {
            obj = JsonParser.parseString(json).getAsJsonObject();
            if (!obj.has("version") || !obj.has("type")) {
                return;
            }
            version = obj.get("version").getAsInt();
            type = obj.get("type").getAsString();
        } catch (RuntimeException e) {
            // A single malformed line must never tear down the reader thread.
            return;
        }
        if (version != PROTOCOL_VERSION) {
            return;
        }
        try {
            switch (type) {
                case "pose" -> {
                    float[] pos = parseFloatArray(obj.getAsJsonArray("position_m"), 3);
                    float[] rot = parseFloatArray(obj.getAsJsonArray("orientation_xyzw"), 4);
                    String tracking = obj.get("tracking_state").getAsString();
                    int recenter = obj.has("recenter_counter") ? obj.get("recenter_counter").getAsInt() : 0;
                    long ts = obj.get("timestamp_ns").getAsLong();
                    latestPose = new Pose(ts, pos, rot, tracking, recenter);
                    lastPoseTimestampNs.set(ts);
                    recenterCounter.set(recenter);
                    BridgeMetrics.get().onPose(ts);
                }
                case "session" -> sessionState = SessionState.fromString(obj.get("state").getAsString());
                case "recenter" -> {
                    if (obj.has("recenter_counter")) {
                        recenterCounter.set(obj.get("recenter_counter").getAsInt());
                    }
                }
                case "pong" -> { /* latency probe */ }
                default -> { /* ignore */ }
            }
        } catch (RuntimeException e) {
            // Field-level parse issue (missing/!numeric field on a known type):
            // skip this message, keep the reader alive.
        }
    }

    private static float[] parseFloatArray(com.google.gson.JsonArray arr, int expected) {
        float[] out = new float[expected];
        for (int i = 0; i < expected; i++) {
            out[i] = arr.get(i).getAsFloat();
        }
        return out;
    }

    public synchronized void sendFrame(FramePacket frame) throws IOException {
        ensureConnected();
        if (sessionState != SessionState.READY) {
            throw new IOException("Session not ready: " + sessionState);
        }
        JsonObject meta = new JsonObject();
        meta.addProperty("type", "frame");
        meta.addProperty("version", PROTOCOL_VERSION);
        meta.addProperty("frame_id", frame.frameId());
        meta.addProperty("timestamp_ns", frame.timestampNs());
        meta.addProperty("near", frame.near());
        meta.addProperty("far", frame.far());

        JsonObject left = eyeMeta(frame.leftWidth(), frame.leftHeight(), frame.leftRgba().length);
        JsonObject right = eyeMeta(frame.rightWidth(), frame.rightHeight(), frame.rightRgba().length);
        meta.add("left", left);
        meta.add("right", right);

        writeLine(meta);
        out.write(frame.leftRgba());
        out.write(frame.rightRgba());
        out.flush();
    }

    private static JsonObject eyeMeta(int w, int h, int byteLength) {
        JsonObject eye = new JsonObject();
        eye.addProperty("width", w);
        eye.addProperty("height", h);
        eye.addProperty("format", "rgba8");
        eye.addProperty("byte_length", byteLength);
        return eye;
    }

    public synchronized void requestRecenter() throws IOException {
        ensureConnected();
        JsonObject msg = new JsonObject();
        msg.addProperty("type", "recenter");
        msg.addProperty("version", PROTOCOL_VERSION);
        writeLine(msg);
        out.flush();
    }

    public synchronized void ping(long timestampNs) throws IOException {
        ensureConnected();
        JsonObject msg = new JsonObject();
        msg.addProperty("type", "ping");
        msg.addProperty("version", PROTOCOL_VERSION);
        msg.addProperty("timestamp_ns", timestampNs);
        writeLine(msg);
        out.flush();
    }

    private void writeLine(JsonObject obj) throws IOException {
        byte[] bytes = (GSON.toJson(obj) + "\n").getBytes(StandardCharsets.UTF_8);
        out.write(bytes);
    }

    private void ensureConnected() throws IOException {
        if (!connected.get() || out == null) {
            throw new IOException("Not connected to VisionCraft host");
        }
    }

    public boolean isConnected() {
        return connected.get();
    }

    public SessionState getSessionState() {
        return sessionState;
    }

    public Pose getLatestPose() {
        return latestPose;
    }

    public int getRecenterCounter() {
        return recenterCounter.get();
    }

    public long getLastPoseTimestampNs() {
        return lastPoseTimestampNs.get();
    }

    @Override
    public synchronized void close() {
        connected.set(false);
        sessionState = SessionState.CLOSED;
        if (socket != null) {
            try {
                socket.close();
            } catch (IOException ignored) {
            }
        }
        if (readerThread != null) {
            readerThread.interrupt();
        }
    }

    public record Pose(
        long timestampNs,
        float[] positionM,
        float[] orientationXyzw,
        String trackingState,
        int recenterCounter
    ) {
        public static Pose identity() {
            return new Pose(0L, new float[]{0f, 1.65f, 0f}, new float[]{0f, 0f, 0f, 1f}, "valid", 0);
        }

        public boolean isValid() {
            return "valid".equals(trackingState);
        }
    }

    public record FramePacket(
        long frameId,
        long timestampNs,
        int leftWidth,
        int leftHeight,
        byte[] leftRgba,
        int rightWidth,
        int rightHeight,
        byte[] rightRgba,
        float near,
        float far
    ) {}

    public enum SessionState {
        READY, PAUSED, LOST, CLOSED;

        public static SessionState fromString(String s) {
            return switch (s.toLowerCase()) {
                case "ready" -> READY;
                case "paused" -> PAUSED;
                case "lost" -> LOST;
                default -> CLOSED;
            };
        }
    }
}
