package visioncraft.bridge;

import java.util.concurrent.atomic.AtomicLong;

/** Rolling counters for frame transport diagnostics (M1+). */
public final class BridgeMetrics {
    private static final BridgeMetrics INSTANCE = new BridgeMetrics();

    private final AtomicLong framesSubmitted = new AtomicLong();
    private final AtomicLong framesDropped = new AtomicLong();
    private final AtomicLong posesReceived = new AtomicLong();
    private volatile long lastCopyTimeNs;
    private volatile long lastSubmitTimeNs;
    private volatile long lastPoseAgeNs;

    public static BridgeMetrics get() {
        return INSTANCE;
    }

    public void onFrameSubmitted(long copyNs, long submitNs) {
        framesSubmitted.incrementAndGet();
        lastCopyTimeNs = copyNs;
        lastSubmitTimeNs = submitNs;
    }

    public void onFrameDropped() {
        framesDropped.incrementAndGet();
    }

    public void onPose(long timestampNs) {
        posesReceived.incrementAndGet();
        lastPoseAgeNs = System.nanoTime() - timestampNs;
    }

    public long getFramesSubmitted() {
        return framesSubmitted.get();
    }

    public long getFramesDropped() {
        return framesDropped.get();
    }

    public long getPosesReceived() {
        return posesReceived.get();
    }

    public long getLastCopyTimeNs() {
        return lastCopyTimeNs;
    }

    public long getLastSubmitTimeNs() {
        return lastSubmitTimeNs;
    }

    public long getLastPoseAgeNs() {
        return lastPoseAgeNs;
    }

    public String summary() {
        return String.format(
            "frames=%d dropped=%d poses=%d copyMs=%.2f submitMs=%.2f poseAgeMs=%.2f",
            framesSubmitted.get(),
            framesDropped.get(),
            posesReceived.get(),
            lastCopyTimeNs / 1_000_000.0,
            lastSubmitTimeNs / 1_000_000.0,
            lastPoseAgeNs / 1_000_000.0
        );
    }
}
