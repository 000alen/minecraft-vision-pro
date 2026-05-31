package visioncraft.bridge;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class BridgeProtocolTest {

    @Test
    void sessionStateParsing() {
        assertEquals(AppleNativeBridge.SessionState.READY, AppleNativeBridge.SessionState.fromString("ready"));
        assertEquals(AppleNativeBridge.SessionState.PAUSED, AppleNativeBridge.SessionState.fromString("paused"));
        assertEquals(AppleNativeBridge.SessionState.CLOSED, AppleNativeBridge.SessionState.fromString("closed"));
    }

    @Test
    void poseIdentityValid() {
        AppleNativeBridge.Pose p = AppleNativeBridge.Pose.identity();
        assertTrue(p.isValid());
        assertEquals(1.65f, p.positionM()[1], 1e-3f);
    }

    @Test
    void visionProFlipPreservesUnitQuaternion() {
        float[] q = {0f, 0.1f, 0f, 0.995f};
        BridgeMath.visionProToMinecraft(q);
        float len = (float) Math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
        assertEquals(1f, len, 1e-3f);
    }
}
