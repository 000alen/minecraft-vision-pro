package org.vivecraft.client_vr.provider.apple;

import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import org.vivecraft.client.VivecraftVRMod;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.openvr_lwjgl.VRInputAction;
import visioncraft.bridge.AppleNativeBridge;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Maps ALVRClient controller/hand input into Vivecraft actions.
 */
public final class AppleInputProvider {
    private static final long STALE_INPUT_NS = 250_000_000L;
    private static final float AXIS_DEADZONE = 0.15F;
    private static final float TRIGGER_THRESHOLD = 0.55F;

    private final AppleNativeBridge bridge;
    private final Map<Long, ControllerType> originHands = new HashMap<>();
    private final Map<Long, String> originNames = new HashMap<>();
    private final Map<KeyMapping, Long> lastBindingOrigin = new HashMap<>();
    private boolean hasFreshControllerState = false;
    private boolean hasSeenControllerState = false;

    public AppleInputProvider(AppleNativeBridge bridge) {
        this.bridge = bridge;
    }

    public void processInputs(AppleVisionProvider provider) {
        AppleNativeBridge.ControllerState state = this.freshControllerState();
        this.hasFreshControllerState = state.timestampNs() != 0L;
        this.hasSeenControllerState |= bridge.getControllerState().timestampNs() != 0L;

        this.applyHand(provider, ControllerType.LEFT, state.left());
        this.applyHand(provider, ControllerType.RIGHT, state.right());
        if (state.left().tracked()) {
            provider.applyBridgeControllerPose(ControllerType.LEFT, state.left());
        }
        if (state.right().tracked()) {
            provider.applyBridgeControllerPose(ControllerType.RIGHT, state.right());
        }
        updateDigital(provider, ControllerType.RIGHT, VivecraftVRMod.INSTANCE.keyMenuButton,
            menuPressed(state.left()) || menuPressed(state.right()), "menu");
    }

    public boolean hasFreshControllerState() {
        return hasFreshControllerState;
    }

    public boolean hasSeenControllerState() {
        return hasSeenControllerState;
    }

    public ControllerType findActiveBindingControllerType(KeyMapping keyMapping) {
        Long origin = lastBindingOrigin.get(keyMapping);
        return origin == null ? null : originHands.get(origin);
    }

    public ControllerType getOriginControllerType(long origin) {
        return originHands.get(origin);
    }

    public String getOriginName(long origin) {
        return originNames.getOrDefault(origin, "AppleVision");
    }

    public List<Long> getOrigins(VRInputAction action) {
        long origin = action.getLastOrigin();
        return origin == 0L ? List.of() : List.of(origin);
    }

    public boolean handleRecenterHotkey(int key, int action) {
        // Wired via VRHotkeys / AppleVisionProvider
        return false;
    }

    private AppleNativeBridge.ControllerState freshControllerState() {
        AppleNativeBridge.ControllerState state = bridge.getControllerState();
        long timestampNs = state.timestampNs();
        long nowNs = System.currentTimeMillis() * 1_000_000L;
        if (!bridge.isConnected() || timestampNs == 0L || nowNs - timestampNs > STALE_INPUT_NS) {
            return AppleNativeBridge.ControllerState.empty();
        }
        return state;
    }

    private void applyHand(
        AppleVisionProvider provider,
        ControllerType hand,
        AppleNativeBridge.Controller controller
    ) {
        Minecraft mc = Minecraft.getInstance();
        VivecraftVRMod mod = VivecraftVRMod.INSTANCE;

        float trigger = Math.max(controller.axis("trigger"), controller.button("trigger_click") ? 1.0F : 0.0F);
        float squeeze = Math.max(controller.axis("squeeze"), controller.button("squeeze_click") ? 1.0F : 0.0F);
        float thumbstickX = applyDeadzone(controller.axis("thumbstick_x"));
        float thumbstickY = applyDeadzone(controller.axis("thumbstick_y"));

        if (hand == ControllerType.LEFT) {
            updateDigital(provider, hand, mc.options.keyUse, trigger > TRIGGER_THRESHOLD, "left_trigger");
            updateDigital(provider, hand, mod.keyVRInteract, squeeze > TRIGGER_THRESHOLD, "left_squeeze");
            updateDigital(provider, hand, mod.keyClimbeyGrab, squeeze > TRIGGER_THRESHOLD, "left_squeeze_climb");
            updateAnalog2D(provider, hand, mod.keyFreeMoveStrafe, thumbstickX, thumbstickY, "left_thumbstick");
            updateDigital(provider, hand, mc.options.keyInventory, controller.button("x"), "left_x");
            updateDigital(provider, hand, mod.keyRadialMenu, controller.button("y"), "left_y");
        } else {
            updateDigital(provider, hand, mc.options.keyAttack, trigger > TRIGGER_THRESHOLD, "right_trigger");
            updateDigital(provider, hand, mod.keyVRInteract, squeeze > TRIGGER_THRESHOLD, "right_squeeze");
            updateDigital(provider, hand, mod.keyClimbeyGrab, squeeze > TRIGGER_THRESHOLD, "right_squeeze_climb");
            updateAnalog2D(provider, hand, mod.keyFreeMoveRotate, thumbstickX, 0.0F, "right_thumbstick");
            updateDigital(provider, hand, mc.options.keyJump, controller.button("a"), "right_a");
            updateDigital(provider, hand, mc.options.keyShift, controller.button("b"), "right_b");
        }
    }

    private static boolean menuPressed(AppleNativeBridge.Controller controller) {
        return controller.button("menu_click") || controller.button("system_click");
    }

    private void updateDigital(
        AppleVisionProvider provider,
        ControllerType hand,
        KeyMapping keyMapping,
        boolean pressed,
        String originName
    ) {
        VRInputAction action = provider.getInputAction(keyMapping);
        if (action == null) {
            return;
        }

        long origin = origin(hand, originName);
        action.setCurrentHand(hand);
        action.updateDigital(hand, pressed, pressed, origin);
        if (pressed && action.isEnabled()) {
            action.pressBinding();
            lastBindingOrigin.put(keyMapping, origin);
        } else {
            action.unpressBinding();
            if (!pressed) {
                lastBindingOrigin.remove(keyMapping);
            }
        }
    }

    private void updateAnalog2D(
        AppleVisionProvider provider,
        ControllerType hand,
        KeyMapping keyMapping,
        float x,
        float y,
        String originName
    ) {
        VRInputAction action = provider.getInputAction(keyMapping);
        if (action == null) {
            return;
        }

        boolean active = x != 0.0F || y != 0.0F;
        long origin = origin(hand, originName);
        action.setCurrentHand(hand);
        action.updateAnalog(hand, active, active ? x : 0.0F, active ? y : 0.0F, 0.0F, origin);
        if (active) {
            lastBindingOrigin.put(keyMapping, origin);
        } else {
            lastBindingOrigin.remove(keyMapping);
        }
    }

    private long origin(ControllerType hand, String name) {
        long handBits = hand == ControllerType.LEFT ? 0x2000_0000_0000_0000L : 0x1000_0000_0000_0000L;
        long origin = handBits | (Integer.toUnsignedLong(name.hashCode()) << 1) | 1L;
        originHands.put(origin, hand);
        originNames.put(origin, "AppleVision " + name);
        return origin;
    }

    private static float applyDeadzone(float value) {
        return Math.abs(value) < AXIS_DEADZONE ? 0.0F : Math.max(-1.0F, Math.min(1.0F, value));
    }
}
