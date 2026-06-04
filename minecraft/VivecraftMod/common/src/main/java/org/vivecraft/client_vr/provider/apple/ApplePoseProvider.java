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
    private static final long POSE_STALE_NS = 250_000_000L;

    private final AppleNativeBridge bridge;
    private final Vector3f position = new Vector3f(0f, 1.62f, 0f);
    private final Quaternionf orientation = new Quaternionf();
    private int lastRecenterCounter;
    /** ALVR sample timestamp of the pose last applied to the HMD (echoed on the rendered frame). */
    private volatile long renderSampleTimestampNs = 0L;

    public ApplePoseProvider(AppleNativeBridge bridge) {
        this.bridge = bridge;
    }

    public void poll() {
        AppleNativeBridge.Pose pose = bridge.getLatestPose();
        if (!pose.isValid()) {
            return;
        }
        long now = System.nanoTime();
        long poseAgeNs = pose.timestampNs() > 0 ? now - pose.timestampNs() : 0;
        if (poseAgeNs > POSE_STALE_NS) {
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
        renderSampleTimestampNs = pose.sampleTimestampNs();
    }

    /**
     * ALVR sample timestamp of the most recently applied head pose. The frame submitter tags the
     * outgoing frame with this so the host can hand ALVR the timestamp the frame was rendered for,
     * letting the client reproject (timewarp) against the correct pose instead of a newer one.
     */
    public long getRenderSampleTimestampNs() {
        return renderSampleTimestampNs;
    }

    /**
     * Writes the head pose (world position + orientation) into Vivecraft's HMD
     * matrices. Per-eye IPD is intentionally NOT applied here — it lives in
     * {@code hmdPoseLeftEye/RightEye}, which {@code MCVR.getEyePosition} composes
     * as {@code hmdPose * hmdPoseEye}.
     */
    public void applyToHmd(Matrix4f hmdPose, Matrix4f hmdRotation) {
        hmdPose.identity();
        hmdPose.rotate(orientation);
        hmdPose.setTranslation(position);

        hmdRotation.set(orientation);
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
