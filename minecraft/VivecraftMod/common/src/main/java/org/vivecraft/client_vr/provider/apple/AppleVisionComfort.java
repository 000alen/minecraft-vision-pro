package org.vivecraft.client_vr.provider.apple;

import org.vivecraft.client_vr.settings.VRSettings;

/**
 * MVP comfort defaults for seated Mac + Vision Pro play.
 */
public final class AppleVisionComfort {

    private AppleVisionComfort() {}

    public static void applyDefaults(VRSettings settings) {
        settings.seated = true;
        settings.seatedUseHMD = true;
        settings.aimDevice = VRSettings.AimDevice.HMD;
        settings.walkMultiplier = Math.min(settings.walkMultiplier, 1.0f);
        if (settings.walkMultiplier < 0.5f) {
            settings.walkMultiplier = 0.85f;
        }
        settings.allowStandingOriginOffset = false;
        settings.physicalKeyboard = true;
        VRSettings.LOGGER.info("Vivecraft: Apple Vision comfort defaults applied (seated, HMD aim)");
    }
}
