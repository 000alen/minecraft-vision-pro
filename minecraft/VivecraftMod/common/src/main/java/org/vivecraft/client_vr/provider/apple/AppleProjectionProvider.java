package org.vivecraft.client_vr.provider.apple;

import com.mojang.blaze3d.systems.RenderSystem;
import net.minecraft.util.Mth;
import org.joml.Matrix4f;
import org.vivecraft.client_vr.ClientDataHolderVR;

/**
 * Symmetric perspective projections for seated stereo (MVP).
 */
public final class AppleProjectionProvider {
    private static final float DEFAULT_FOV_DEG = 100f;

    private AppleProjectionProvider() {}

    /**
     * Per-eye projection. This is a pure view frustum — the inter-pupillary eye
     * separation is applied by {@link AppleVisionProvider} via the eye-to-head
     * matrices ({@code hmdPoseLeftEye/RightEye}), exactly like the OpenVR and NullVR
     * backends. Baking an IPD translate in here as well would double-apply parallax.
     *
     * @param aspect width / height of the eye render target. Must match the eye
     *               framebuffer or the image is horizontally stretched/squished.
     */
    public static Matrix4f projectionForEye(int eyeIndex, float nearClip, float farClip, float aspect) {
        float fovRad = Mth.DEG_TO_RAD * eyeFovDegrees();
        float safeAspect = aspect > 0f ? aspect : 1.0f;
        return new Matrix4f().setPerspective(
            fovRad, safeAspect, nearClip, farClip, RenderSystem.getDevice().isZZeroToOne());
    }

    private static float eyeFovDegrees() {
        ClientDataHolderVR dh = ClientDataHolderVR.getInstance();
        if (dh != null && dh.vrSettings != null) {
            return dh.vrSettings.nullvrFOV > 0 ? dh.vrSettings.nullvrFOV : DEFAULT_FOV_DEG;
        }
        return DEFAULT_FOV_DEG;
    }
}
