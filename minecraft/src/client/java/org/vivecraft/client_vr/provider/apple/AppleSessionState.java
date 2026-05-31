package org.vivecraft.client_vr.provider.apple;

import visioncraft.bridge.AppleNativeBridge;

/**
 * Tracks VisionCraft host session state from bridge messages.
 */
public final class AppleSessionState {
    private volatile AppleNativeBridge.SessionState state = AppleNativeBridge.SessionState.CLOSED;
    private volatile int lastRecenterCounter;

    public void updateFromBridge(AppleNativeBridge bridge) {
        this.state = bridge.getSessionState();
        this.lastRecenterCounter = bridge.getRecenterCounter();
    }

    public boolean isReady() {
        return state == AppleNativeBridge.SessionState.READY;
    }

    public AppleNativeBridge.SessionState getState() {
        return state;
    }

    public int getLastRecenterCounter() {
        return lastRecenterCounter;
    }

    public boolean recenterChanged(int counter) {
        if (counter != lastRecenterCounter) {
            lastRecenterCounter = counter;
            return true;
        }
        return false;
    }
}
