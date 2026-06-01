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

import java.io.IOException;

/**
 * Stereo renderer that submits frames to VisionCraftHost via {@link AppleFrameSubmitter}.
 */
public class AppleVisionStereoRenderer extends VRRenderer {
    private static final int DEFAULT_WIDTH = 1512;
    private static final int DEFAULT_HEIGHT = 1680;

    private final AppleVisionProvider provider;
    private final AppleFrameSubmitter submitter;
    private int eyeWidth = DEFAULT_WIDTH;
    private int eyeHeight = DEFAULT_HEIGHT;

    public AppleVisionStereoRenderer(AppleVisionProvider provider, AppleFrameSubmitter submitter) {
        super(provider);
        this.provider = provider;
        this.submitter = submitter;
    }

    @Override
    public Tuple<Integer, Integer> getRenderTextureSizes() {
        if (this.resolution == null) {
            this.resolution = new Tuple<>(eyeWidth, eyeHeight);
            VRSettings.LOGGER.info("Vivecraft: Apple Vision render res {}x{}", eyeWidth, eyeHeight);
            this.ss = -1.0F;
        }
        return this.resolution;
    }

    @Override
    protected Matrix4f getProjectionMatrix(int eyeType, float nearClip, float farClip) {
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
        float near = 0.05f;
        float far = this.lastFarClip > 0 ? this.lastFarClip : 512f;
        try {
            submitter.submitEyeTextures(LeftEyeTextureId, RightEyeTextureId, eyeWidth, eyeHeight, near, far);
        } catch (IOException e) {
            throw new RenderConfigException(
                net.minecraft.network.chat.Component.literal("VisionCraft bridge error"),
                net.minecraft.network.chat.Component.literal(e.getMessage() != null ? e.getMessage() : "I/O error")
            );
        }
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
