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
    private static final float DEFAULT_IPD_M = 0.064f;

    private AppleProjectionProvider() {}

    public static Matrix4f projectionForEye(int eyeIndex, float nearClip, float farClip) {
        float fovRad = Mth.DEG_TO_RAD * eyeFovDegrees();
        float ipd = eyeIpdMeters();
        float offset = (eyeIndex == 0 ? -0.5f : 0.5f) * ipd;
        float aspect = 1.0f; // square eye buffers in MVP
        return new Matrix4f().setPerspective(fovRad, aspect, nearClip, farClip, RenderSystem.getDevice().isZZeroToOne())
            .translate(offset, 0f, 0f);
    }

    private static float eyeFovDegrees() {
        ClientDataHolderVR dh = ClientDataHolderVR.getInstance();
        if (dh != null && dh.vrSettings != null) {
            return dh.vrSettings.nullvrFOV > 0 ? dh.vrSettings.nullvrFOV : DEFAULT_FOV_DEG;
        }
        return DEFAULT_FOV_DEG;
    }

    private static float eyeIpdMeters() {
        ClientDataHolderVR dh = ClientDataHolderVR.getInstance();
        if (dh != null && dh.vrSettings != null) {
            return dh.vrSettings.nullvrIPD > 0 ? dh.vrSettings.nullvrIPD : DEFAULT_IPD_M;
        }
        return DEFAULT_IPD_M;
    }
}
