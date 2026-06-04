package org.vivecraft.client_vr.provider.apple;

import com.mojang.blaze3d.opengl.GlStateManager;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL15;
import org.lwjgl.opengl.GL21;
import org.lwjgl.opengl.GL30;
import org.vivecraft.client_vr.settings.VRSettings;
import visioncraft.bridge.AppleNativeBridge;
import visioncraft.bridge.AsyncFrameSender;
import visioncraft.bridge.BridgeMetrics;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.File;
import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Reads back the stereo eye textures and submits them to VisionCraftHost.
 *
 * <p><b>Async readback (double-buffered PBOs).</b> Each frame issues a {@code glGetTexImage}
 * into a pixel-pack buffer (a non-blocking GPU→buffer DMA) and maps the <em>previous</em>
 * frame's buffer, whose transfer already completed. This removes the synchronous
 * GPU→CPU stall a direct {@code glGetTexImage}-to-client-memory incurs, at the cost of one
 * frame of transport latency (the host reprojects against its own latest pose anyway).
 *
 * <p><b>Off-thread send + pooling.</b> The mapped pixels are copied into the
 * {@link AsyncFrameSender}'s pooled buffers and sent on its dedicated thread, so the render
 * thread never blocks on socket I/O and the hot path performs no per-frame heap allocation.
 *
 * <p>All GL calls run on the render thread. PBOs are GL objects, so they are released via
 * {@link #releaseGlResources()} (called from the renderer's {@code destroyBuffers()} with the
 * context current) — never from {@link #close()}, which may run without a GL context.
 */
public final class AppleFrameSubmitter implements AutoCloseable {

    /** Metadata captured when a readback is issued, replayed when its buffer is mapped. */
    private static final class Pending {
        boolean filled;
        long frameId;
        long timestampNs;
        float near;
        float far;
        int width;
        int height;
        float[] renderOrientation;
    }

    // Debug PNG dump of the pristine per-eye game render (before any host processing). Off unless
    // -Dvisioncraft.dumpFrames=N is set; writes upright PNGs to -Dvisioncraft.dumpDir on the async
    // sender thread so it never stalls the render thread. See bridge/protocol.md (bottom-left origin).
    private static final int DUMP_FRAMES = Integer.getInteger("visioncraft.dumpFrames", 0);
    private static final String DUMP_DIR =
        System.getProperty("visioncraft.dumpDir", ".run/captures/vivecraft");
    private final AtomicInteger dumpRemaining = new AtomicInteger(DUMP_FRAMES);

    private final AppleNativeBridge bridge;
    private final AsyncFrameSender sender;
    private final AtomicLong frameId = new AtomicLong();
    private final AtomicLong lastSendFailureLogNs = new AtomicLong();

    // Ping-pong pixel-pack buffers per eye (index 0/1) and the metadata for each slot.
    private final int[] pboLeft = {0, 0};
    private final int[] pboRight = {0, 0};
    private final Pending[] meta = {new Pending(), new Pending()};
    private int slot = 0;
    private int pboBytes = -1;

    public AppleFrameSubmitter(AppleNativeBridge bridge) {
        this.bridge = bridge;
        this.sender = new AsyncFrameSender(frame -> {
            maybeDumpFrame(frame);
            long t = System.nanoTime();
            bridge.sendFrame(new AppleNativeBridge.FramePacket(
                frame.frameId(), frame.timestampNs(),
                frame.width(), frame.height(), frame.left(),
                frame.width(), frame.height(), frame.right(),
                frame.near(), frame.far(), frame.renderOrientationXyzw()));
            BridgeMetrics.get().onFrameSubmitted(frame.copyTimeNs(), System.nanoTime() - t);
        }, this::recordSendFailure);
    }

    /**
     * Issue this frame's async readback and queue the previously-read frame for sending.
     * Returns immediately; neither the GPU readback nor the socket write blocks the caller.
     */
    public void submitEyeTextures(int leftTextureId, int rightTextureId, int width, int height,
        float near, float far, float[] renderOrientation, long renderSampleTimestampNs) {
        if (!bridge.isConnected() || bridge.getSessionState() != AppleNativeBridge.SessionState.READY) {
            clearPendingReadbacks();
            BridgeMetrics.get().onFrameDropped();
            return;
        }
        int size = width * height * 4;
        if (size <= 0) {
            clearPendingReadbacks();
            return;
        }

        int prevTexture = GlStateManager._getInteger(GL11.GL_TEXTURE_BINDING_2D);
        int prevPackBuffer = GlStateManager._getInteger(GL21.GL_PIXEL_PACK_BUFFER_BINDING);
        try {
            ensurePbos(size); // clears pending slots if the size changed (e.g. resolution change)

            int cur = slot;
            int prev = 1 - slot;

            // 1) Kick off this frame's transfer into the current slot (non-blocking DMA).
            issueReadback(leftTextureId, pboLeft[cur]);
            issueReadback(rightTextureId, pboRight[cur]);
            Pending m = meta[cur];
            m.frameId = frameId.incrementAndGet();
            // Carry the ALVR sample timestamp of the rendered pose (not a capture-clock value) so
            // the host can submit the frame to ALVR under the timestamp it was rendered for, which
            // is what the client's reprojection keys on. Falls back handled host-side when 0.
            m.timestampNs = renderSampleTimestampNs;
            m.near = near;
            m.far = far;
            m.width = width;
            m.height = height;
            m.renderOrientation = renderOrientation;
            m.filled = true;

            // 2) Map the previous slot (its DMA finished last frame) and send it.
            Pending p = meta[prev];
            if (p.filled) {
                AsyncFrameSender.Frame frame = sender.beginFrame(p.width, p.height);
                long t0 = System.nanoTime();
                boolean ok = mapInto(pboLeft[prev], frame.left())
                    && mapInto(pboRight[prev], frame.right());
                if (ok) {
                    frame.setCopyTimeNs(System.nanoTime() - t0);
                    sender.commitFrame(frame, p.frameId, p.timestampNs, p.near, p.far, p.renderOrientation);
                    if (p.frameId % 90 == 0) {
                        VRSettings.LOGGER.debug("VisionCraft: {} backpressureDropped={}",
                            BridgeMetrics.get().summary(), sender.droppedFrames());
                    }
                } else {
                    sender.abandon(frame);
                    BridgeMetrics.get().onFrameDropped();
                }
                p.filled = false;
            }

            slot = prev;
        } finally {
            GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER, prevPackBuffer);
            GlStateManager._bindTexture(prevTexture);
        }
    }

    /** Bind {@code tex} and start an async read of its level-0 RGBA8 into the bound PBO. */
    private void issueReadback(int textureId, int pbo) {
        GlStateManager._bindTexture(textureId);
        GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER, pbo);
        // pixels == 0: write into the bound pixel-pack buffer at offset 0 (non-blocking).
        GL11.glGetTexImage(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, 0L);
    }

    /** Map a completed PBO read-only and copy it into {@code dst}. */
    private boolean mapInto(int pbo, byte[] dst) {
        GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER, pbo);
        ByteBuffer mapped = GL30.glMapBufferRange(GL21.GL_PIXEL_PACK_BUFFER, 0, dst.length, GL30.GL_MAP_READ_BIT);
        if (mapped == null) {
            return false;
        }
        mapped.get(dst, 0, dst.length);
        return GL15.glUnmapBuffer(GL21.GL_PIXEL_PACK_BUFFER);
    }

    private void ensurePbos(int size) {
        if (pboLeft[0] == 0) {
            for (int i = 0; i < 2; i++) {
                pboLeft[i] = GL15.glGenBuffers();
                pboRight[i] = GL15.glGenBuffers();
            }
        }
        if (size != pboBytes) {
            for (int i = 0; i < 2; i++) {
                specBuffer(pboLeft[i], size);
                specBuffer(pboRight[i], size);
                meta[i].filled = false; // stale reads are the wrong size now
            }
            pboBytes = size;
        }
    }

    /** Reset monotonic frame ids after the bridge session becomes ready (new ALVR stream). */
    public void resetFrameIds() {
        frameId.set(0);
        clearPendingReadbacks();
    }

    private void clearPendingReadbacks() {
        for (Pending pending : meta) {
            pending.filled = false;
            pending.renderOrientation = null;
        }
        slot = 0;
    }

    /**
     * Dump the first {@code visioncraft.dumpFrames} frames' per-eye RGBA8 buffers as upright PNGs.
     * Runs on the async sender thread (never the render thread). RGBA8 is bottom-left origin (OpenGL),
     * so rows are flipped to produce a visually upright image.
     */
    private void maybeDumpFrame(AsyncFrameSender.Frame frame) {
        if (dumpRemaining.get() <= 0 || dumpRemaining.getAndDecrement() <= 0) {
            return;
        }
        try {
            File dir = new File(DUMP_DIR);
            if (!dir.exists() && !dir.mkdirs()) {
                VRSettings.LOGGER.warn("VisionCraft: could not create dump dir {}", dir.getAbsolutePath());
                return;
            }
            String stem = String.format("frame_%08d", frame.frameId());
            writeEyePng(frame.left(), frame.width(), frame.height(), new File(dir, stem + "_left.png"));
            writeEyePng(frame.right(), frame.width(), frame.height(), new File(dir, stem + "_right.png"));
            VRSettings.LOGGER.info("VisionCraft: dumped frame {} eyes ({}x{}) to {}",
                frame.frameId(), frame.width(), frame.height(), dir.getAbsolutePath());
        } catch (Exception e) {
            VRSettings.LOGGER.warn("VisionCraft: frame dump failed: {}", e.getMessage());
        }
    }

    private static void writeEyePng(byte[] rgba, int width, int height, File out) throws Exception {
        if (rgba == null || width <= 0 || height <= 0 || rgba.length < width * height * 4) {
            return;
        }
        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        int rowBytes = width * 4;
        for (int y = 0; y < height; y++) {
            int srcRow = (height - 1 - y) * rowBytes; // flip bottom-left -> top-left
            for (int x = 0; x < width; x++) {
                int i = srcRow + x * 4;
                int r = rgba[i] & 0xFF;
                int g = rgba[i + 1] & 0xFF;
                int b = rgba[i + 2] & 0xFF;
                int a = rgba[i + 3] & 0xFF;
                img.setRGB(x, y, (a << 24) | (r << 16) | (g << 8) | b);
            }
        }
        ImageIO.write(img, "png", out);
    }

    private void recordSendFailure(Throwable failure) {
        BridgeMetrics.get().onFrameDropped();
        long now = System.nanoTime();
        long previous = lastSendFailureLogNs.get();
        if (now - previous < 2_000_000_000L || !lastSendFailureLogNs.compareAndSet(previous, now)) {
            return;
        }
        VRSettings.LOGGER.warn("VisionCraft: frame send failed: {}", failure.getMessage());
    }

    private static void specBuffer(int pbo, int size) {
        GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER, pbo);
        GL15.glBufferData(GL21.GL_PIXEL_PACK_BUFFER, size, GL15.GL_STREAM_READ);
    }

    /** Delete the PBOs. Must be called on the render thread with the GL context current. */
    public void releaseGlResources() {
        if (pboLeft[0] == 0) {
            return;
        }
        for (int i = 0; i < 2; i++) {
            GL15.glDeleteBuffers(pboLeft[i]);
            GL15.glDeleteBuffers(pboRight[i]);
            pboLeft[i] = 0;
            pboRight[i] = 0;
            meta[i].filled = false;
        }
        pboBytes = -1;
    }

    public long getDroppedFrames() {
        return sender.droppedFrames();
    }

    public long getSendFailures() {
        return sender.sendFailures();
    }

    @Override
    public void close() {
        sender.close();
    }
}
