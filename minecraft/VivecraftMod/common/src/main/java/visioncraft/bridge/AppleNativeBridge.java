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
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

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
    private final AtomicBoolean closeRequested = new AtomicBoolean(false);
    private final AtomicLong lastPoseTimestampNs = new AtomicLong(0L);
    private final AtomicLong connectionGeneration = new AtomicLong(0L);
    private final AtomicInteger recenterCounter = new AtomicInteger(0);

    private volatile Pose latestPose = Pose.identity();
    private volatile SessionState sessionState = SessionState.CLOSED;
    private volatile ViewConfig latestViewConfig = null;
    private volatile HandState latestHands = HandState.empty();
    private volatile ControllerState latestControllerState = ControllerState.empty();
    private volatile String lastDisconnectCause = null;

    private Socket socket;
    private BufferedOutputStream out;
    private Thread readerThread;
    private long activeConnectionGeneration = 0L;

    public AppleNativeBridge() {
        this(BridgeSettings.host(), BridgeSettings.port());
    }

    public AppleNativeBridge(String host, int port) {
        this.host = host;
        this.port = port;
    }

    public synchronized void connect() throws IOException {
        connectInternal(5000);
    }

    /** Connect once with a caller-selected timeout, useful for non-blocking reconnect probes. */
    public synchronized void connect(int timeoutMs) throws IOException {
        connectInternal(timeoutMs);
    }

    /** Connect with retries while VisionCraftHost is starting. */
    public synchronized void connectWithRetry(int attempts, long delayMs) throws IOException {
        IOException last = null;
        for (int i = 0; i < attempts; i++) {
            try {
                connectInternal(5000);
                return;
            } catch (IOException e) {
                last = e;
                disconnect(SessionState.LOST, e.getMessage(), true);
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

    private void connectInternal(int timeoutMs) throws IOException {
        if (connected.get()) {
            return;
        }
        closeSocketResources();
        Socket newSocket = new Socket();
        try {
            newSocket.connect(new InetSocketAddress(host, port), timeoutMs);
            newSocket.setTcpNoDelay(true);
            InputStream in = new BufferedInputStream(newSocket.getInputStream());
            BufferedOutputStream newOut = new BufferedOutputStream(newSocket.getOutputStream());

            long generation = connectionGeneration.incrementAndGet();
            socket = newSocket;
            out = newOut;
            activeConnectionGeneration = generation;
            closeRequested.set(false);
            clearRemoteState();
            lastDisconnectCause = null;
            sessionState = SessionState.CLOSED;
            connected.set(true);
            readerThread = new Thread(() -> readLoop(generation, newSocket, in, newOut), "visioncraft-bridge-reader");
            readerThread.setDaemon(true);
            readerThread.start();
        } catch (IOException e) {
            try {
                newSocket.close();
            } catch (IOException ignored) {
            }
            lastDisconnectCause = e.getMessage();
            sessionState = SessionState.LOST;
            throw e;
        }
    }

    private void readLoop(
        long generation,
        Socket ownedSocket,
        InputStream in,
        BufferedOutputStream ownedOut
    ) {
        StringBuilder line = new StringBuilder();
        String disconnectCause = "VisionCraft host closed the bridge";
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
            disconnectCause = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
        } finally {
            SessionState state = closeRequested.get() ? SessionState.CLOSED : SessionState.LOST;
            String cause = closeRequested.get() ? null
                : (lastDisconnectCause != null ? lastDisconnectCause : disconnectCause);
            disconnectIfOwner(generation, ownedSocket, ownedOut, state, cause);
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
                close();
                return;
            }
            version = obj.get("version").getAsInt();
            type = obj.get("type").getAsString();
        } catch (RuntimeException e) {
            close();
            return;
        }
        if (version != PROTOCOL_VERSION) {
            close();
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
                case "view_config" -> {
                    ViewConfig parsed = parseViewConfig(obj);
                    if (parsed != null) {
                        latestViewConfig = parsed;
                    }
                }
                case "hand" -> {
                    HandState parsed = parseHands(obj);
                    if (parsed != null) {
                        latestHands = parsed;
                    }
                }
                case "controller" -> {
                    ControllerState parsed = parseControllerState(obj);
                    if (parsed != null) {
                        latestControllerState = parsed;
                    }
                }
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

    /**
     * Parse a {@code view_config} object into per-eye tangents/dimensions. Returns
     * {@code null} (caller keeps the previous config) if the message is incomplete or both
     * eyes cannot be resolved, so a malformed update never clobbers a good config.
     */
    private static ViewConfig parseViewConfig(JsonObject obj) {
        if (!obj.has("views")) {
            return null;
        }
        com.google.gson.JsonArray views = obj.getAsJsonArray("views");
        float[] leftTan = null, rightTan = null;
        int leftW = 0, leftH = 0, rightW = 0, rightH = 0;
        for (int i = 0; i < views.size(); i++) {
            JsonObject view = views.get(i).getAsJsonObject();
            int index = view.get("index").getAsInt();
            float[] tan = parseFloatArray(view.getAsJsonArray("tangents"), 4);
            int w = view.has("width") ? view.get("width").getAsInt() : 0;
            int h = view.has("height") ? view.get("height").getAsInt() : 0;
            if (index == 0) {
                leftTan = tan;
                leftW = w;
                leftH = h;
            } else if (index == 1) {
                rightTan = tan;
                rightW = w;
                rightH = h;
            }
        }
        if (leftTan == null || rightTan == null) {
            return null;
        }
        float ipd = obj.has("ipd_m") ? obj.get("ipd_m").getAsFloat() : 0f;
        return new ViewConfig(leftTan, rightTan, leftW, leftH, rightW, rightH, ipd);
    }

    /**
     * Parse a {@code hand} message into a {@link HandState}. Returns {@code null} (caller
     * keeps the previous state) only if the {@code hands} array is absent. Hands not present
     * in the message default to untracked, so a one-handed update releases the other hand.
     */
    private static HandState parseHands(JsonObject obj) {
        if (!obj.has("hands")) {
            return null;
        }
        com.google.gson.JsonArray hands = obj.getAsJsonArray("hands");
        Hand left = Hand.untracked();
        Hand right = Hand.untracked();
        for (int i = 0; i < hands.size(); i++) {
            JsonObject h = hands.get(i).getAsJsonObject();
            if (!h.has("chirality")) {
                continue;
            }
            boolean tracked = h.has("tracked") && h.get("tracked").getAsBoolean();
            float pinch = h.has("pinch") ? h.get("pinch").getAsFloat() : 0f;
            float pinchMiddle = h.has("pinch_middle") ? h.get("pinch_middle").getAsFloat() : 0f;
            float[] pos = h.has("position_m") ? parseFloatArray(h.getAsJsonArray("position_m"), 3)
                : new float[]{0f, 0f, 0f};
            float[] ori = h.has("orientation_xyzw") ? parseFloatArray(h.getAsJsonArray("orientation_xyzw"), 4)
                : new float[]{0f, 0f, 0f, 1f};
            Hand hand = new Hand(tracked, pinch, pinchMiddle, pos, ori);
            if ("left".equals(h.get("chirality").getAsString())) {
                left = hand;
            } else {
                right = hand;
            }
        }
        long timestampNs = obj.has("timestamp_ns") ? obj.get("timestamp_ns").getAsLong() : 0L;
        return new HandState(timestampNs, left, right);
    }

    /**
     * Parse a full controller message. Missing hands default to untracked so a partial update
     * releases stale input from the absent side.
     */
    private static ControllerState parseControllerState(JsonObject obj) {
        if (!obj.has("controllers")) {
            return null;
        }
        long timestampNs = obj.has("timestamp_ns") ? obj.get("timestamp_ns").getAsLong() : 0L;
        com.google.gson.JsonArray controllers = obj.getAsJsonArray("controllers");
        Controller left = Controller.untracked();
        Controller right = Controller.untracked();
        for (int i = 0; i < controllers.size(); i++) {
            JsonObject c = controllers.get(i).getAsJsonObject();
            if (!c.has("hand")) {
                continue;
            }
            boolean tracked = c.has("tracked") && c.get("tracked").getAsBoolean();
            float[] pos = c.has("position_m") ? parseFloatArray(c.getAsJsonArray("position_m"), 3)
                : new float[]{0f, 0f, 0f};
            float[] ori = c.has("orientation_xyzw") ? parseFloatArray(c.getAsJsonArray("orientation_xyzw"), 4)
                : new float[]{0f, 0f, 0f, 1f};
            Controller controller = new Controller(
                tracked,
                parseBooleanMap(c, "buttons"),
                parseFloatMap(c, "axes"),
                pos,
                ori
            );
            if ("left".equals(c.get("hand").getAsString())) {
                left = controller;
            } else {
                right = controller;
            }
        }
        return new ControllerState(timestampNs, left, right);
    }

    private static Map<String, Boolean> parseBooleanMap(JsonObject obj, String key) {
        if (!obj.has(key) || !obj.get(key).isJsonObject()) {
            return Map.of();
        }
        Map<String, Boolean> values = new HashMap<>();
        for (Map.Entry<String, com.google.gson.JsonElement> entry : obj.getAsJsonObject(key).entrySet()) {
            values.put(entry.getKey(), entry.getValue().getAsBoolean());
        }
        return Map.copyOf(values);
    }

    private static Map<String, Float> parseFloatMap(JsonObject obj, String key) {
        if (!obj.has(key) || !obj.get(key).isJsonObject()) {
            return Map.of();
        }
        Map<String, Float> values = new HashMap<>();
        for (Map.Entry<String, com.google.gson.JsonElement> entry : obj.getAsJsonObject(key).entrySet()) {
            values.put(entry.getKey(), entry.getValue().getAsFloat());
        }
        return Map.copyOf(values);
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

        // Render head orientation (ARKit world, xyzw) for client-side rotational reprojection.
        // Omitted when unknown so the viewer cleanly falls back to a no-op warp.
        float[] orientation = frame.renderOrientationXyzw();
        if (orientation != null && orientation.length == 4) {
            com.google.gson.JsonArray q = new com.google.gson.JsonArray(4);
            for (float c : orientation) {
                q.add(c);
            }
            meta.add("render_orientation_xyzw", q);
        }

        JsonObject left = eyeMeta(frame.leftWidth(), frame.leftHeight(), frame.leftRgba().length);
        JsonObject right = eyeMeta(frame.rightWidth(), frame.rightHeight(), frame.rightRgba().length);
        meta.add("left", left);
        meta.add("right", right);

        try {
            writeLine(meta);
            out.write(frame.leftRgba());
            out.write(frame.rightRgba());
            out.flush();
        } catch (IOException e) {
            disconnect(SessionState.LOST, e.getMessage(), true);
            throw e;
        }
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
        try {
            writeLine(msg);
            out.flush();
        } catch (IOException e) {
            disconnect(SessionState.LOST, e.getMessage(), true);
            throw e;
        }
    }

    public synchronized void ping(long timestampNs) throws IOException {
        ensureConnected();
        JsonObject msg = new JsonObject();
        msg.addProperty("type", "ping");
        msg.addProperty("version", PROTOCOL_VERSION);
        msg.addProperty("timestamp_ns", timestampNs);
        try {
            writeLine(msg);
            out.flush();
        } catch (IOException e) {
            disconnect(SessionState.LOST, e.getMessage(), true);
            throw e;
        }
    }

    public synchronized void sendHaptic(
        String hand,
        float durationSeconds,
        float frequencyHz,
        float amplitude
    ) throws IOException {
        ensureConnected();
        JsonObject msg = new JsonObject();
        msg.addProperty("type", "haptic");
        msg.addProperty("version", PROTOCOL_VERSION);
        msg.addProperty("hand", hand);
        msg.addProperty("duration_s", durationSeconds);
        msg.addProperty("frequency_hz", frequencyHz);
        msg.addProperty("amplitude", amplitude);
        try {
            writeLine(msg);
            out.flush();
        } catch (IOException e) {
            disconnect(SessionState.LOST, e.getMessage(), true);
            throw e;
        }
    }

    private void writeLine(JsonObject obj) throws IOException {
        byte[] bytes = (GSON.toJson(obj) + "\n").getBytes(StandardCharsets.UTF_8);
        out.write(bytes);
    }

    private void ensureConnected() throws IOException {
        if (!connected.get() || out == null) {
            String suffix = lastDisconnectCause == null ? "" : ": " + lastDisconnectCause;
            throw new IOException("Not connected to VisionCraft host" + suffix);
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

    /** Latest device frustum/IPD from the host, or {@code null} if none received yet. */
    public ViewConfig getViewConfig() {
        return latestViewConfig;
    }

    /** Latest per-hand tracking state. Never {@code null}; both hands untracked until reported. */
    public HandState getHands() {
        return latestHands;
    }

    /** Latest ALVR controller input state. Never {@code null}; both hands untracked until reported. */
    public ControllerState getControllerState() {
        return latestControllerState;
    }

    /** Most recent transport-level disconnect cause, or {@code null} after a clean close/connect. */
    public String getLastDisconnectCause() {
        return lastDisconnectCause;
    }

    public int getRecenterCounter() {
        return recenterCounter.get();
    }

    public long getLastPoseTimestampNs() {
        return lastPoseTimestampNs.get();
    }

    @Override
    public synchronized void close() {
        closeRequested.set(true);
        disconnect(SessionState.CLOSED, null, true);
    }

    private synchronized void disconnect(SessionState state, String cause, boolean interruptReader) {
        connected.set(false);
        sessionState = state;
        lastDisconnectCause = cause;
        clearRemoteState();
        closeSocketResources();
        if (interruptReader && readerThread != null && readerThread != Thread.currentThread()) {
            readerThread.interrupt();
        }
    }

    private synchronized void disconnectIfOwner(
        long generation,
        Socket ownedSocket,
        BufferedOutputStream ownedOut,
        SessionState state,
        String cause
    ) {
        if (activeConnectionGeneration != generation || socket != ownedSocket || out != ownedOut) {
            closeOwnedSocketResources(ownedOut, ownedSocket);
            return;
        }
        connected.set(false);
        sessionState = state;
        lastDisconnectCause = cause;
        clearRemoteState();
        closeSocketResources();
    }

    private void clearRemoteState() {
        latestPose = Pose.identity();
        latestViewConfig = null;
        latestControllerState = ControllerState.empty();
        latestHands = HandState.empty();
        recenterCounter.set(0);
        lastPoseTimestampNs.set(0L);
    }

    private void closeSocketResources() {
        BufferedOutputStream currentOut = out;
        out = null;
        if (currentOut != null) {
            try {
                currentOut.close();
            } catch (IOException ignored) {
            }
        }
        Socket currentSocket = socket;
        socket = null;
        activeConnectionGeneration = 0L;
        if (currentSocket != null) {
            try {
                currentSocket.close();
            } catch (IOException ignored) {
            }
        }
    }

    private static void closeOwnedSocketResources(BufferedOutputStream ownedOut, Socket ownedSocket) {
        if (ownedOut != null) {
            try {
                ownedOut.close();
            } catch (IOException ignored) {
            }
        }
        if (ownedSocket != null) {
            try {
                ownedSocket.close();
            } catch (IOException ignored) {
            }
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

    /**
     * Device per-eye view frustum reported by the host. {@code tangents} are the positive
     * tangents of the frustum half-angles in {@code [left, right, up, down]} order (same
     * convention as Compositor Services). Width/height are the device's recommended per-eye
     * viewport in pixels (advisory). {@code ipdM} is the measured inter-pupillary distance.
     */
    public record ViewConfig(
        float[] leftTangents,
        float[] rightTangents,
        int leftWidth,
        int leftHeight,
        int rightWidth,
        int rightHeight,
        float ipdM
    ) {
        /** Tangents for the given eye (0 = left, else right). */
        public float[] tangentsForEye(int eyeType) {
            return eyeType == 0 ? leftTangents : rightTangents;
        }
    }

    /**
     * A single hand's tracking state. {@code positionM} (wrist, meters) and
     * {@code orientationXyzw} (raw ARKit wrist orientation) are advisory — the seated profile
     * aims with the head and consumes only {@code pinch} (0..1 strength). See protocol docs.
     */
    public record Hand(
        boolean tracked,
        float pinch,
        float pinchMiddle,
        float[] positionM,
        float[] orientationXyzw
    ) {
        public static Hand untracked() {
            return new Hand(false, 0f, 0f, new float[]{0f, 0f, 0f}, new float[]{0f, 0f, 0f, 1f});
        }
    }

    /** Both hands' latest state. */
    public record HandState(long timestampNs, Hand left, Hand right) {
        public static HandState empty() {
            return new HandState(0L, Hand.untracked(), Hand.untracked());
        }
    }

    /** A controller's current binary/axis input and advisory wrist/controller pose. */
    public record Controller(
        boolean tracked,
        Map<String, Boolean> buttons,
        Map<String, Float> axes,
        float[] positionM,
        float[] orientationXyzw
    ) {
        public static Controller untracked() {
            return new Controller(false, Map.of(), Map.of(), new float[]{0f, 0f, 0f}, new float[]{0f, 0f, 0f, 1f});
        }

        public boolean button(String name) {
            return buttons.getOrDefault(name, false);
        }

        public float axis(String name) {
            return axes.getOrDefault(name, 0f);
        }
    }

    /** Latest state for both ALVR controller hands. */
    public record ControllerState(long timestampNs, Controller left, Controller right) {
        public static ControllerState empty() {
            return new ControllerState(0L, Controller.untracked(), Controller.untracked());
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
        float far,
        /** Head orientation (ARKit world, xyzw) the frame was rendered for, or {@code null}. */
        float[] renderOrientationXyzw
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
