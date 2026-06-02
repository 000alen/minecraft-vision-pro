package org.vivecraft.client_vr.provider.apple;

import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.HapticScheduler;
import visioncraft.bridge.AppleNativeBridge;

import java.io.IOException;
import java.util.concurrent.TimeUnit;

/** Sends Vivecraft haptic pulses back through ALVR when the headset/client supports them. */
public class AppleVisionHapticScheduler extends HapticScheduler {
    private final AppleNativeBridge bridge;

    public AppleVisionHapticScheduler(AppleNativeBridge bridge) {
        this.bridge = bridge;
    }

    @Override
    public void queueHapticPulse(ControllerType controller, float durationSeconds, float frequency,
        float amplitude, float delaySeconds)
    {
        long delayMs = Math.max(0L, Math.round(delaySeconds * 1000.0F));
        this.executor.schedule(() -> {
            if (!bridge.isConnected()) {
                return;
            }
            try {
                bridge.sendHaptic(
                    controller == ControllerType.LEFT ? "left" : "right",
                    Math.max(0.0F, durationSeconds),
                    Math.max(0.0F, frequency),
                    Math.max(0.0F, Math.min(1.0F, amplitude))
                );
            } catch (IOException ignored) {
                // The next bridge/session update will release or reconnect; haptics are best-effort.
            }
        }, delayMs, TimeUnit.MILLISECONDS);
    }
}
