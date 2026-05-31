package org.vivecraft.client_vr.provider.apple;

import org.joml.Matrix4f;
import org.joml.Quaternionf;
import org.joml.Vector3f;
import visioncraft.bridge.AppleNativeBridge;
import visioncraft.bridge.BridgeMath;

/**
 * Applies bridge head pose to Vivecraft HMD matrices (Minecraft Y-up).
 */
public final class ApplePoseProvider {
    private final AppleNativeBridge bridge;
    private final Vector3f position = new Vector3f(0f, 1.62f, 0f);
    private final Quaternionf orientation = new Quaternionf();
    private int lastRecenterCounter;

    public ApplePoseProvider(AppleNativeBridge bridge) {
        this.bridge = bridge;
    }

    public void poll() {
        AppleNativeBridge.Pose pose = bridge.getLatestPose();
        if (!pose.isValid()) {
            return;
        }
        float[] p = pose.positionM();
        position.set(
            BridgeMath.metersToBlocks(p[0]),
            BridgeMath.metersToBlocks(p[1]),
            BridgeMath.metersToBlocks(p[2])
        );
        float[] q = pose.orientationXyzw().clone();
        BridgeMath.visionProToMinecraft(q);
        orientation.set(q[0], q[1], q[2], q[3]);
        lastRecenterCounter = pose.recenterCounter();
    }

    public void applyToHmd(Matrix4f hmdPose, Matrix4f hmdRotation, float ipd) {
        hmdPose.identity();
        hmdPose.rotate(orientation);
        hmdPose.setTranslation(position);

        hmdRotation.set(orientation);

        // eye offsets along local X
        // left/right applied by AppleVisionProvider on hmdPoseLeftEye / RightEye
    }

    public float getYawRadians() {
        float[] q = new float[]{orientation.x, orientation.y, orientation.z, orientation.w};
        return BridgeMath.yawFromQuaternion(q);
    }

    public float getPitchRadians() {
        float[] q = new float[]{orientation.x, orientation.y, orientation.z, orientation.w};
        return BridgeMath.pitchFromQuaternion(q);
    }

    public boolean consumeRecenterEvent() {
        int c = bridge.getRecenterCounter();
        if (c != lastRecenterCounter) {
            lastRecenterCounter = c;
            return true;
        }
        return false;
    }
}
