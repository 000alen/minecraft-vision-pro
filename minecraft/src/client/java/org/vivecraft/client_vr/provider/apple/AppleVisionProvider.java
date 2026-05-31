package org.vivecraft.client_vr.provider.apple;

import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.util.Mth;
import net.minecraft.util.profiling.Profiler;
import org.apache.commons.lang3.tuple.Triple;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.lwjgl.glfw.GLFW;
import org.vivecraft.client.VivecraftVRMod;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.MethodHolder;
import org.vivecraft.client_vr.provider.*;
import org.vivecraft.client_vr.provider.openvr_lwjgl.VRInputAction;
import org.vivecraft.client_vr.settings.VRSettings;
import visioncraft.bridge.AppleNativeBridge;

import java.io.IOException;
import java.util.List;

/**
 * Vivecraft MCVR backend for Mac → Vision Pro via VisionCraftHost.
 * Does not load OpenVR / SteamVR.
 */
public class AppleVisionProvider extends MCVR {
    private static AppleVisionProvider instance;

    private final AppleNativeBridge bridge = new AppleNativeBridge();
    private final AppleSessionState sessionState = new AppleSessionState();
    private final ApplePoseProvider poseProvider;
    private final AppleInputProvider inputProvider = new AppleInputProvider();
    private AppleFrameSubmitter frameSubmitter;
    private AppleVisionHapticScheduler hapticScheduler;

    public AppleVisionProvider(Minecraft mc, ClientDataHolderVR dh) {
        super(mc, dh, VivecraftVRMod.INSTANCE);
        instance = this;
        this.poseProvider = new ApplePoseProvider(bridge);
        this.hapticScheduler = new AppleVisionHapticScheduler();
    }

    public static AppleVisionProvider get() {
        return instance;
    }

    @Override
    public String getName() {
        return "appleVision";
    }

    @Override
    public String getRuntimeName() {
        return "VisionCraft";
    }

    @Override
    public boolean init() {
        if (this.initialized) {
            return true;
        }
        try {
            bridge.connect();
            frameSubmitter = new AppleFrameSubmitter(bridge);
            VRSettings.LOGGER.info("Vivecraft: Apple Vision provider connected to VisionCraft host");
        } catch (IOException e) {
            this.initStatus = "VisionCraft host not running: " + e.getMessage();
            VRSettings.LOGGER.error("Vivecraft: {}", initStatus);
            this.initSuccess = false;
            return false;
        }

        this.dh.vrSettings.seated = true;
        this.headIsTracking = true;
        this.hmdPose.identity();
        this.hmdPose.m31(1.62F);
        float ipd = getIPD();
        this.hmdPoseLeftEye.m30(-ipd * 0.5F);
        this.hmdPoseRightEye.m30(ipd * 0.5F);
        this.populateInputActions();
        this.initialized = true;
        this.initSuccess = true;
        return true;
    }

    @Override
    public void destroy() {
        bridge.close();
        super.destroy();
        this.initialized = false;
    }

    @Override
    public void poll(long frameIndex) {
        if (!this.initialized) {
            return;
        }
        sessionState.updateFromBridge(bridge);
        Profiler.get().push("applePose");
        poseProvider.poll();
        poseProvider.applyToHmd(hmdPose, hmdRotation, getIPD());
        float ipd = getIPD();
        this.hmdPoseLeftEye.set(this.hmdPose).translate(-ipd * 0.5F, 0f, 0f);
        this.hmdPoseRightEye.set(this.hmdPose).translate(ipd * 0.5F, 0f, 0f);
        if (poseProvider.consumeRecenterEvent()) {
            this.seatedRot = 0f;
            VRSettings.LOGGER.info("Vivecraft: Apple Vision recenter applied");
        }
        Profiler.get().popPush("appleInput");
        inputProvider.processInputs();
        this.processInputs();
        Profiler.get().popPush("hmdSampling");
        this.hmdSampling();
        Profiler.get().pop();
    }

    @Override
    public void processInputs() {
        this.ignorePressesNextFrame = false;
    }

    @Override
    protected ControllerType findActiveBindingControllerType(KeyMapping keyMapping) {
        return inputProvider.findActiveBindingControllerType(keyMapping);
    }

    @Override
    public void refreshControllerTransforms() {}

    @Override
    public Matrix4fc getControllerComponentTransform(int controllerIndex, String componentName) {
        return new Matrix4f();
    }

    @Override
    public String getOriginName(long origin) {
        return "AppleVision";
    }

    @Override
    public boolean hasCameraTracker() {
        return false;
    }

    @Override
    public List<Long> getOrigins(VRInputAction action) {
        return List.of();
    }

    @Override
    public VRRenderer createVRRenderer() {
        return new AppleVisionStereoRenderer(this, frameSubmitter);
    }

    @Override
    public boolean isActive() {
        return sessionState.isReady();
    }

    @Override
    public boolean capFPS() {
        return true;
    }

    @Override
    public float getIPD() {
        return this.dh.vrSettings.nullvrIPD;
    }

    @Override
    public boolean handleKeyboardInputs(int key, int scanCode, int action, int modifiers) {
        if (action == GLFW.GLFW_PRESS && key == GLFW.GLFW_KEY_R &&
            MethodHolder.isKeyDown(GLFW.GLFW_KEY_LEFT_CONTROL))
        {
            try {
                bridge.requestRecenter();
            } catch (IOException e) {
                VRSettings.LOGGER.warn("Vivecraft: recenter failed: {}", e.getMessage());
            }
            return true;
        }
        return false;
    }

    public AppleNativeBridge getBridge() {
        return bridge;
    }
}
