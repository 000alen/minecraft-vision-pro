package org.vivecraft.client_vr.provider.apple;

import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.settings.VRSettings;

/**
 * Guards OpenVR native init when using the Apple Vision backend.
 */
public final class VisionCraftRuntime {

    public static final String PROP_SKIP_OPENVR = "visioncraft.skipOpenVR";
    public static final String ENV_SKIP_OPENVR = "VISIONCRAFT_SKIP_OPENVR";

    private VisionCraftRuntime() {}

    public static boolean skipOpenVR() {
        if (Boolean.getBoolean(PROP_SKIP_OPENVR)) {
            return true;
        }
        String env = System.getenv(ENV_SKIP_OPENVR);
        if (env != null && (env.equalsIgnoreCase("1") || env.equalsIgnoreCase("true"))) {
            return true;
        }
        try {
            ClientDataHolderVR dh = ClientDataHolderVR.getInstance();
            if (dh != null && dh.vrSettings != null) {
                return dh.vrSettings.stereoProviderPluginID == VRSettings.VRProvider.APPLE_VISION;
            }
        } catch (Throwable ignored) {
        }
        return false;
    }
}
