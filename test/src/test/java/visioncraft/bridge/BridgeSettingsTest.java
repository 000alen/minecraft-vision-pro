package visioncraft.bridge;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class BridgeSettingsTest {

    @Test
    void defaultsWhenUnset() {
        assertEquals(AppleNativeBridge.DEFAULT_HOST, BridgeSettings.host());
        assertEquals(AppleNativeBridge.DEFAULT_PORT, BridgeSettings.port());
    }
}
