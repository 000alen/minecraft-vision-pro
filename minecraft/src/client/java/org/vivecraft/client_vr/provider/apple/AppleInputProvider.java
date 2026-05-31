package org.vivecraft.client_vr.provider.apple;

import net.minecraft.client.KeyMapping;
import org.vivecraft.client_vr.provider.ControllerType;

/**
 * MVP input: keyboard/mouse on Mac; fake controllers (no hand tracking).
 */
public final class AppleInputProvider {

    public void processInputs() {
        // Keyboard/mouse handled by vanilla + Vivecraft mixins
    }

    public ControllerType findActiveBindingControllerType(KeyMapping keyMapping) {
        return null;
    }

    public boolean handleRecenterHotkey(int key, int action) {
        // Wired via VRHotkeys / AppleVisionProvider
        return false;
    }
}
