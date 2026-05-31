package org.vivecraft.client_vr.provider.apple;

import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.util.profiling.Profiler;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Vector2f;
import org.joml.Vector3f;
import org.lwjgl.glfw.GLFW;
import org.vivecraft.client.VivecraftVRMod;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.MethodHolder;
import org.vivecraft.client_vr.gameplay.screenhandlers.GuiHandler;
import org.vivecraft.client_vr.provider.*;
import org.vivecraft.client_vr.provider.openvr_lwjgl.VRInputAction;
import org.vivecraft.client_vr.settings.VRSettings;
import org.vivecraft.common.utils.MathUtils;
import visioncraft.bridge.AppleNativeBridge;
import visioncraft.bridge.BridgeSettings;

import java.io.IOException;
import java.util.List;

/**
 * Vivecraft MCVR backend for Mac → Vision Pro via VisionCraftHost.
 * Does not load OpenVR / SteamVR.
 */
public class AppleVisionProvider extends MCVR {
    private static AppleVisionProvider instance;

    private static final float CROSSHAIR_FORWARD_BLOCKS = 0.75f;

    private final AppleNativeBridge bridge = new AppleNativeBridge(BridgeSettings.host(), BridgeSettings.port());
    private final AppleSessionState sessionState = new AppleSessionState();
    private final ApplePoseProvider poseProvider;
    private final AppleInputProvider inputProvider = new AppleInputProvider();
    private AppleFrameSubmitter frameSubmitter;
    private boolean vrActive = true;

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
    public Vector2fc getPlayAreaSize() {
        return new Vector2f(2f, 2f);
    }

    @Override
    public boolean init() {
        if (this.initialized) {
            return true;
        }
        try {
            bridge.connectWithRetry(20, 250);
            frameSubmitter = new AppleFrameSubmitter(bridge);
            VRSettings.LOGGER.info("Vivecraft: Apple Vision connected to VisionCraft host :{}", AppleNativeBridge.DEFAULT_PORT);
        } catch (IOException e) {
            this.initStatus = "Start VisionCraftHost first. " + e.getMessage();
            VRSettings.LOGGER.error("Vivecraft: {}", initStatus);
            this.initSuccess = false;
            return false;
        }

        AppleVisionComfort.applyDefaults(this.dh.vrSettings);
        this.headIsTracking = true;
        this.hmdPose.identity();
        this.hmdPose.m31(1.62F);
        applyEyeOffsets();
        this.populateInputActions();
        this.initialized = true;
        this.initSuccess = true;
        return true;
    }

    private void applyEyeOffsets() {
        float ipd = getIPD();
        this.hmdPoseLeftEye.identity().m30(-ipd * 0.5F);
        this.hmdPoseRightEye.identity().m30(ipd * 0.5F);
    }

    @Override
    public void destroy() {
        bridge.close();
        super.destroy();
        this.initialized = false;
        instance = null;
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
        applyEyeOffsetsFromHead();
        if (poseProvider.consumeRecenterEvent()) {
            this.seatedRot = 0f;
            VRSettings.LOGGER.info("Vivecraft: Apple Vision recenter applied");
        }
        updateFakeControllers();
        this.updateAim();
        if (this.dh.vrSettings.seated) {
            if (GuiHandler.GUI_ROTATION_ROOM != null) {
                this.hmdRotation.set3x3(GuiHandler.GUI_ROTATION_ROOM);
            }
        }
        Profiler.get().popPush("appleInput");
        inputProvider.processInputs();
        this.processInputs();
        Profiler.get().popPush("hmdSampling");
        this.hmdSampling();
        Profiler.get().pop();
    }

    private void applyEyeOffsetsFromHead() {
        float ipd = getIPD();
        this.hmdPoseLeftEye.set(this.hmdPose).translate(-ipd * 0.5F, 0f, 0f);
        this.hmdPoseRightEye.set(this.hmdPose).translate(ipd * 0.5F, 0f, 0f);
    }

    /** Head-forward ray for crosshair / block interaction without motion controllers. */
    private void updateFakeControllers() {
        Matrix4f forward = new Matrix4f(this.hmdPose).translate(0f, 0f, -CROSSHAIR_FORWARD_BLOCKS);
        this.controllerPose[MAIN_CONTROLLER].set(forward);
        this.controllerPose[OFFHAND_CONTROLLER].set(forward);
        this.controllerRotation[MAIN_CONTROLLER].set(this.hmdRotation);
        this.controllerRotation[OFFHAND_CONTROLLER].set(this.hmdRotation);
        this.controllerTracking[MAIN_CONTROLLER] = this.headIsTracking;
        this.controllerTracking[OFFHAND_CONTROLLER] = this.headIsTracking;
        this.handRotation[MAIN_CONTROLLER].set(this.hmdRotation);
        this.handRotation[OFFHAND_CONTROLLER].set(this.hmdRotation);
        this.deviceSource[MAIN_CONTROLLER].set(DeviceSource.Source.APPLE, MAIN_CONTROLLER);
        this.deviceSource[OFFHAND_CONTROLLER].set(DeviceSource.Source.APPLE, OFFHAND_CONTROLLER);
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
        return new Matrix4f(this.controllerPose[controllerIndex]);
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
        return this.vrActive && this.initialized;
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
        if (MethodHolder.isKeyDown(GLFW.GLFW_KEY_RIGHT_CONTROL) && action == GLFW.GLFW_PRESS && key == GLFW.GLFW_KEY_F6) {
            this.vrActive = !this.vrActive;
            return true;
        }
        return false;
    }

    public AppleNativeBridge getBridge() {
        return bridge;
    }

    public boolean isHostSessionReady() {
        return sessionState.isReady();
    }
}
