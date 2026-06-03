package visioncraft.bridge.test;

/** Compatibility entry point for older docs/scripts. */
public final class FakeStereoFrameSender {
    private FakeStereoFrameSender() {}

    public static void main(String[] args) throws Exception {
        BridgeTestPatternSender.main(args);
    }
}
