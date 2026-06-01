package org.vivecraft.client_vr.provider.apple;

import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.HapticScheduler;

/** No-op haptics for MVP. */
public class AppleVisionHapticScheduler extends HapticScheduler {
    @Override
    public void queueHapticPulse(ControllerType controller, float durationSeconds, float frequency,
        float amplitude, float delaySeconds) {}
}
