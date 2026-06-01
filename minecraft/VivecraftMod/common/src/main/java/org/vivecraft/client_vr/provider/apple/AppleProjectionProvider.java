package org.vivecraft.client_vr.provider.apple;

import com.mojang.blaze3d.systems.RenderSystem;
import net.minecraft.util.Mth;
import org.joml.Matrix4f;
import org.vivecraft.client_vr.ClientDataHolderVR;

/**
 * Per-eye perspective projections for seated stereo. Uses the device's true asymmetric
 * frustum tangents when the host has reported a {@code view_config}; otherwise falls back
 * to a symmetric FOV.
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

    /**
     * Off-axis perspective from the device's true per-eye frustum tangents (sent by the host
     * via {@code view_config}). {@code tangents} are positive {@code [left, right, up, down]}
     * tangents of the half-angles; the eye frustum is asymmetric (nasal edge smaller). Built
     * with Minecraft's own near/far so render distance is preserved.
     *
     * <p>The host blits the entire Java eye buffer to the entire device viewport, so the
     * frustum's aspect is encoded in the tangents themselves — the Java buffer resolution
     * does not need to match the device viewport for geometric correctness.</p>
     */
    public static Matrix4f projectionFromTangents(float[] tangents, float nearClip, float farClip) {
        float left = -tangents[0] * nearClip;
        float right = tangents[1] * nearClip;
        float top = tangents[2] * nearClip;
        float bottom = -tangents[3] * nearClip;
        return new Matrix4f().frustum(
            left, right, bottom, top, nearClip, farClip, RenderSystem.getDevice().isZZeroToOne());
    }

    private static float eyeFovDegrees() {
        ClientDataHolderVR dh = ClientDataHolderVR.getInstance();
        if (dh != null && dh.vrSettings != null) {
            return dh.vrSettings.nullvrFOV > 0 ? dh.vrSettings.nullvrFOV : DEFAULT_FOV_DEG;
        }
        return DEFAULT_FOV_DEG;
    }
}
