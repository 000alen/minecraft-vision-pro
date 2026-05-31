package visioncraft.bridge;

/**
 * Bridge connection settings (env / system properties).
 */
public final class BridgeSettings {
    public static final String PROP_HOST = "visioncraft.bridge.host";
    public static final String PROP_PORT = "visioncraft.bridge.port";
    public static final String ENV_HOST = "VISIONCRAFT_BRIDGE_HOST";
    public static final String ENV_PORT = "VISIONCRAFT_BRIDGE_PORT";

    private BridgeSettings() {}

    public static String host() {
        String prop = System.getProperty(PROP_HOST);
        if (prop != null && !prop.isBlank()) {
            return prop.trim();
        }
        String env = System.getenv(ENV_HOST);
        if (env != null && !env.isBlank()) {
            return env.trim();
        }
        return AppleNativeBridge.DEFAULT_HOST;
    }

    public static int port() {
        String prop = System.getProperty(PROP_PORT);
        if (prop != null && !prop.isBlank()) {
            return Integer.parseInt(prop.trim());
        }
        String env = System.getenv(ENV_PORT);
        if (env != null && !env.isBlank()) {
            return Integer.parseInt(env.trim());
        }
        return AppleNativeBridge.DEFAULT_PORT;
    }
}
