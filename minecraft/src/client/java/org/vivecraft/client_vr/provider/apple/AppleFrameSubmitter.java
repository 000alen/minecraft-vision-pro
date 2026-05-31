package org.vivecraft.client_vr.provider.apple;

import com.mojang.blaze3d.opengl.GlStateManager;
import org.lwjgl.opengl.GL11;
import org.lwjgl.system.MemoryUtil;
import visioncraft.bridge.AppleNativeBridge;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicLong;

/**
 * CPU readback of eye textures and bridge submission (MVP transport).
 */
public final class AppleFrameSubmitter {
    private final AppleNativeBridge bridge;
    private final AtomicLong frameId = new AtomicLong();
    private long lastCopyTimeNs;
    private long lastSubmitTimeNs;
    private int droppedFrames;

    public AppleFrameSubmitter(AppleNativeBridge bridge) {
        this.bridge = bridge;
    }

    public void submitEyeTextures(int leftTextureId, int rightTextureId, int width, int height,
        float near, float far) throws IOException {
        if (!bridge.isConnected() || !bridge.getSessionState().equals(AppleNativeBridge.SessionState.READY)) {
            droppedFrames++;
            return;
        }
        long t0 = System.nanoTime();
        byte[] left = readTextureRgba(leftTextureId, width, height);
        byte[] right = readTextureRgba(rightTextureId, width, height);
        lastCopyTimeNs = System.nanoTime() - t0;

        long id = frameId.incrementAndGet();
        long ts = System.nanoTime();
        AppleNativeBridge.FramePacket packet = new AppleNativeBridge.FramePacket(
            id, ts, width, height, left, width, height, right, near, far
        );
        bridge.sendFrame(packet);
        lastSubmitTimeNs = System.nanoTime() - ts;
    }

    private static byte[] readTextureRgba(int textureId, int width, int height) {
        int prev = GlStateManager._getInteger(GL11.GL_TEXTURE_BINDING_2D);
        GlStateManager._bindTexture(textureId);
        int size = width * height * 4;
        ByteBuffer buffer = MemoryUtil.memAlloc(size);
        try {
            GL11.glGetTexImage(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, buffer);
            byte[] out = new byte[size];
            buffer.get(out);
            return out;
        } finally {
            MemoryUtil.memFree(buffer);
            GlStateManager._bindTexture(prev);
        }
    }

    public long getLastCopyTimeNs() {
        return lastCopyTimeNs;
    }

    public long getLastSubmitTimeNs() {
        return lastSubmitTimeNs;
    }

    public int getDroppedFrames() {
        return droppedFrames;
    }
}
