package visioncraft.bridge;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class BridgeMathTest {

    @Test
    void normalizeQuaternion_unit() {
        float[] q = {0f, 0f, 0f, 2f};
        assertTrue(BridgeMath.normalizeQuaternion(q));
        assertEquals(1f, q[3], 1e-5f);
    }

    @Test
    void normalizeQuaternion_zeroFails() {
        float[] q = {0f, 0f, 0f, 0f};
        assertFalse(BridgeMath.normalizeQuaternion(q));
    }

    @Test
    void yawFromIdentity() {
        float[] q = {0f, 0f, 0f, 1f};
        assertEquals(0f, BridgeMath.yawFromQuaternion(q), 1e-4f);
    }

    @Test
    void blocksToMetersIdentity() {
        assertEquals(1.5f, BridgeMath.blocksToMeters(1.5f));
    }
}
