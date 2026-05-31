package visioncraft.bridge;

/**
 * Coordinate and rotation helpers shared by bridge tests and the Vivecraft Apple provider.
 */
public final class BridgeMath {

    private BridgeMath() {}

    /** Normalize quaternion in place; returns false if length is near zero. */
    public static boolean normalizeQuaternion(float[] xyzw) {
        float x = xyzw[0];
        float y = xyzw[1];
        float z = xyzw[2];
        float w = xyzw[3];
        float len = (float) Math.sqrt(x * x + y * y + z * z + w * w);
        if (len < 1e-6f) {
            return false;
        }
        xyzw[0] = x / len;
        xyzw[1] = y / len;
        xyzw[2] = z / len;
        xyzw[3] = w / len;
        return true;
    }

    /**
     * Minecraft seated yaw (radians) from bridge pose quaternion (x,y,z,w).
     * Assumes Y-up; forward is -Z in Minecraft convention after conversion.
     */
    public static float yawFromQuaternion(float[] q) {
        float x = q[0];
        float y = q[1];
        float z = q[2];
        float w = q[3];
        float sinyCosp = 2f * (w * y + x * z);
        float cosyCosp = 1f - 2f * (y * y + z * z);
        return (float) Math.atan2(sinyCosp, cosyCosp);
    }

    public static float pitchFromQuaternion(float[] q) {
        float x = q[0];
        float y = q[1];
        float z = q[2];
        float w = q[3];
        float sinp = 2f * (w * x - y * z);
        if (Math.abs(sinp) >= 1f) {
            return (float) Math.copySign(Math.PI / 2, sinp);
        }
        return (float) Math.asin(sinp);
    }

    /** Blocks to meters (MVP scale). */
    public static float blocksToMeters(float blocks) {
        return blocks;
    }

    public static float metersToBlocks(float meters) {
        return meters;
    }
}
