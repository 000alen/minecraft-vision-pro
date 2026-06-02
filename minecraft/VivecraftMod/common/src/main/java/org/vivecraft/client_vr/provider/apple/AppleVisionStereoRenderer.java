package org.vivecraft.client_vr.provider.apple;

import com.mojang.blaze3d.opengl.GlStateManager;
import com.mojang.blaze3d.systems.RenderSystem;
import net.minecraft.util.Tuple;
import org.joml.Matrix4f;
import org.lwjgl.opengl.GL11;
import org.vivecraft.client_vr.provider.MCVR;
import org.vivecraft.client_vr.provider.VRRenderer;
import org.vivecraft.client_vr.render.RenderConfigException;
import org.vivecraft.client_vr.render.helpers.RenderHelper;
import org.vivecraft.client_vr.settings.VRSettings;
import visioncraft.bridge.AppleNativeBridge;

/**
 * Stereo renderer that submits frames to VisionCraftHost via {@link AppleFrameSubmitter}.
 */
public class AppleVisionStereoRenderer extends VRRenderer {
    private static final int DEFAULT_WIDTH = 1512;
    private static final int DEFAULT_HEIGHT = 1680;
    /** Clamp device-reported dims to a sane range so a garbage view_config can't OOM the GPU. */
    private static final int MIN_DIM = 512;
    private static final int MAX_DIM = 4096;

    private final AppleVisionProvider provider;
    private final AppleFrameSubmitter submitter;
    private int eyeWidth = DEFAULT_WIDTH;
    private int eyeHeight = DEFAULT_HEIGHT;
    /** Log the "waiting for view_config" / "streaming" transitions exactly once each. */
    private boolean loggedWaitingForViewConfig = false;
    private boolean loggedStreamingStarted = false;

    public AppleVisionStereoRenderer(AppleVisionProvider provider, AppleFrameSubmitter submitter) {
        super(provider);
        this.provider = provider;
        this.submitter = submitter;
    }

    @Override
    public Tuple<Integer, Integer> getRenderTextureSizes() {
        if (this.resolution == null) {
            int[] dims = desiredEyeDims();
            this.eyeWidth = dims[0];
            this.eyeHeight = dims[1];
            this.resolution = new Tuple<>(this.eyeWidth, this.eyeHeight);
            VRSettings.LOGGER.info("Vivecraft: Apple Vision render res {}x{}", this.eyeWidth, this.eyeHeight);
            this.ss = -1.0F;
        }
        return this.resolution;
    }

    /**
     * Per-eye render dimensions: the device's recommended {@code view_config} size when the
     * host has reported it (1:1 sampling on the headset), else a sensible default. Values are
     * clamped to {@code [MIN_DIM, MAX_DIM]}.
     */
    private int[] desiredEyeDims() {
        AppleNativeBridge.ViewConfig vc = provider.getBridge().getViewConfig();
        if (vc != null && vc.leftWidth() >= MIN_DIM && vc.leftHeight() >= MIN_DIM) {
            return new int[]{clampDim(vc.leftWidth()), clampDim(vc.leftHeight())};
        }
        return new int[]{DEFAULT_WIDTH, DEFAULT_HEIGHT};
    }

    private static int clampDim(int v) {
        return Math.max(MIN_DIM, Math.min(MAX_DIM, v));
    }

    /**
     * Adopt the device-recommended render size once the host reports it (or if it changes).
     * Updates {@link #resolution} and flags a framebuffer reinit so the next frame rebuilds
     * the eye buffers at the new size. Stable input ⇒ fires at most once.
     */
    private void applyDeviceResolutionIfChanged() {
        int[] dims = desiredEyeDims();
        if (dims[0] != this.eyeWidth || dims[1] != this.eyeHeight) {
            VRSettings.LOGGER.info("Vivecraft: Apple Vision render res -> {}x{} (device view_config)",
                dims[0], dims[1]);
            this.eyeWidth = dims[0];
            this.eyeHeight = dims[1];
            this.resolution = new Tuple<>(dims[0], dims[1]);
            this.ss = -1.0F;
            this.reinitFrameBuffers = true;
        }
    }

    @Override
    protected Matrix4f getProjectionMatrix(int eyeType, float nearClip, float farClip) {
        AppleNativeBridge.ViewConfig viewConfig = provider.getBridge().getViewConfig();
        if (viewConfig != null) {
            // Match the device's true asymmetric frustum exactly (no distortion).
            return AppleProjectionProvider.projectionFromTangents(
                viewConfig.tangentsForEye(eyeType), nearClip, farClip);
        }
        // Fallback before the host reports a view_config: symmetric FOV at buffer aspect.
        float aspect = eyeHeight > 0 ? (float) eyeWidth / (float) eyeHeight : 1.0f;
        return AppleProjectionProvider.projectionForEye(eyeType, nearClip, farClip, aspect);
    }

    @Override
    public void createRenderTexture(int width, int height) {
        this.eyeWidth = width;
        this.eyeHeight = height;
        this.LeftEyeTextureId = createEyeTexture(width, height);
        this.RightEyeTextureId = createEyeTexture(width, height);
        this.lastError = RenderHelper.checkGLError("create Apple VR textures");
    }

    private static int createEyeTexture(int width, int height) {
        int id = GlStateManager._genTexture();
        int bound = GlStateManager._getInteger(GL11.GL_TEXTURE_BINDING_2D);
        GlStateManager._bindTexture(id);
        GlStateManager._texParameter(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_LINEAR);
        GlStateManager._texParameter(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_LINEAR);
        GlStateManager._texImage2D(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA8, width, height, 0, GL11.GL_RGBA, GL11.GL_INT, null);
        GlStateManager._bindTexture(bound);
        return id;
    }

    @Override
    public void endFrame() throws RenderConfigException {
        // Gate streaming on a device view_config. Until it arrives, getProjectionMatrix() falls
        // back to a *symmetric* FOV — but the Vision Pro's lenses use an *asymmetric* per-eye
        // frustum, so symmetric frames cannot be fused by the viewer (the two eye images diverge
        // and "won't merge into one"). Holding frames keeps the headset on its fuseable debug
        // pattern for the ~1 s until the companion's measured view_config round-trips, so the
        // first game frames the user ever sees are already geometrically correct.
        if (provider.getBridge().getViewConfig() == null) {
            if (!loggedWaitingForViewConfig) {
                VRSettings.LOGGER.info("Vivecraft: Apple Vision waiting for device view_config before streaming "
                    + "(headset shows standby pattern; symmetric frames would not fuse)");
                loggedWaitingForViewConfig = true;
            }
            applyDeviceResolutionIfChanged();
            GL11.glFlush();
            return;
        }
        if (!loggedStreamingStarted) {
            VRSettings.LOGGER.info("Vivecraft: Apple Vision view_config acquired — streaming fuseable stereo frames");
            loggedStreamingStarted = true;
        }

        float near = 0.05f;
        float far = this.lastFarClip > 0 ? this.lastFarClip : 512f;
        // Raw ARKit-world head orientation (xyzw) this frame was rendered for. The viewer warps
        // against its own latest ARKit pose, so we pass the unconverted quaternion (NOT the
        // Minecraft-space one). Null when the pose is unknown ⇒ viewer no-ops the reprojection.
        float[] renderOrientation = null;
        AppleNativeBridge.Pose pose = provider.getBridge().getLatestPose();
        if (pose != null && pose.isValid()) {
            renderOrientation = pose.orientationXyzw().clone();
        }
        // submitEyeTextures never blocks on the network: the readback is queued to the
        // async sender thread, so the render thread is not coupled to socket backpressure.
        submitter.submitEyeTextures(LeftEyeTextureId, RightEyeTextureId, eyeWidth, eyeHeight, near, far,
            renderOrientation);
        // Pick up the device-recommended render size once the host reports it (next frame).
        applyDeviceResolutionIfChanged();
        GL11.glFlush();
    }

    @Override
    public boolean providesStencilMask() {
        return false;
    }

    @Override
    public String getName() {
        return "AppleVision";
    }

    @Override
    protected void destroyBuffers() {
        super.destroyBuffers();
        // PBOs are GL objects owned by the submitter; free them here (render thread, context
        // current). They are re-created lazily at the new size on the next submit.
        submitter.releaseGlResources();
        if (LeftEyeTextureId > -1) {
            GlStateManager._deleteTexture(LeftEyeTextureId);
            LeftEyeTextureId = -1;
        }
        if (RightEyeTextureId > -1) {
            GlStateManager._deleteTexture(RightEyeTextureId);
            RightEyeTextureId = -1;
        }
    }
}
