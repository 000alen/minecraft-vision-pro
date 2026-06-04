package org.vivecraft.client_vr.provider.apple;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.TitleScreen;
import org.vivecraft.client.gui.screens.GarbageCollectorScreen;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRState;
import org.vivecraft.client_vr.settings.VRSettings;

/**
 * Mac + Vision Pro boot policy: do not turn on VR during the Mojang loading splash.
 * <p>
 * Remember-VR used to set {@link VRState#VR_ENABLED} on the first resource reload, which
 * initialized stereo while the desktop window still showed the red Mojang screen. That
 * triggered an immediate {@code VR_RUNNING} toggle (window resize flicker), drew an empty
 * eye-buffer mirror into the corner (gray block matching the headset standby view), and
 * could abort startup when {@code setupRenderConfiguration} ran too early.
 */
public final class AppleVisionStartup {

    private static boolean pendingRememberedVr = false;

    private AppleVisionStartup() {}

    public static boolean isAppleVisionProvider() {
        ClientDataHolderVR dh = ClientDataHolderVR.getInstance();
        return dh != null && dh.vrSettings != null
            && dh.vrSettings.stereoProviderPluginID == VRSettings.VRProvider.APPLE_VISION;
    }

    /**
     * Called after the initial resource reload. Defers {@link VRState#VR_ENABLED} until the
     * title screen instead of enabling during the Mojang splash.
     */
    public static void onInitialResourcesLoaded() {
        ClientDataHolderVR dh = ClientDataHolderVR.getInstance();
        if (!isAppleVisionProvider()) {
            return;
        }
        if (dh.vrSettings.vrEnabled && dh.vrSettings.rememberVr) {
            pendingRememberedVr = true;
            VRSettings.LOGGER.info(
                "Vivecraft: Apple Vision will enable VR on the title screen (deferred past Mojang loading)");
        } else {
            pendingRememberedVr = false;
            dh.vrSettings.vrEnabled = false;
            dh.vrSettings.saveOptions();
        }
    }

    /**
     * Enables remembered VR once the player reaches the title screen.
     */
    public static void tryEnableRememberedVrOnTitleScreen(Minecraft mc) {
        if (!pendingRememberedVr || mc == null) {
            return;
        }
        if (!(mc.screen instanceof TitleScreen)) {
            return;
        }
        pendingRememberedVr = false;
        VRState.VR_ENABLED = true;
        VRSettings.LOGGER.info("Vivecraft: Apple Vision enabling remembered VR on title screen");
    }

    /**
     * Keep {@link VRState#VR_RUNNING} off until the title screen so mirror/window resize do not
     * run during the Mojang splash or resource-load overlay.
     */
    public static boolean suppressVrRunning(Minecraft mc) {
        if (!isAppleVisionProvider() || mc == null) {
            return false;
        }
        if (pendingRememberedVr) {
            return true;
        }
        if (mc.getOverlay() != null) {
            return true;
        }
        Screen screen = mc.screen;
        if (screen == null && mc.level == null) {
            return true;
        }
        return !(screen instanceof TitleScreen) && mc.level == null;
    }

    /**
     * Skip desktop VR mirror while modal screens are up or the main window is far smaller than the
     * eye buffers (CROPPED mirror only paints part of the framebuffer — looks like a frozen color block).
     */
    public static boolean suppressDesktopMirror(Minecraft mc) {
        if (!isAppleVisionProvider() || mc == null || !VRState.VR_RUNNING) {
            return false;
        }
        if (mc.screen instanceof GarbageCollectorScreen) {
            return true;
        }
        if (mc.screen != null && mc.screen.isPauseScreen()) {
            return true;
        }
        var renderer = ClientDataHolderVR.getInstance().vrRenderer;
        if (renderer != null && renderer.framebufferEye0 != null) {
            int eyeW = renderer.framebufferEye0.width;
            int mainW = mc.getMainRenderTarget().width;
            if (eyeW > 0 && mainW > 0 && mainW < eyeW / 2) {
                return true;
            }
        }
        return false;
    }
}
