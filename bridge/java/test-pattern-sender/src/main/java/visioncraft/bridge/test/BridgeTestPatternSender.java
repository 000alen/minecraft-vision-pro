package visioncraft.bridge.test;

import visioncraft.bridge.AppleNativeBridge;

import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Bridge v1 proof: sends distinct left/right test patterns and prints pose lines.
 */
public final class BridgeTestPatternSender {
    private static final int WIDTH = 512;
    private static final int HEIGHT = 512;
    private static final long FRAME_INTERVAL_MS = 16;

    private BridgeTestPatternSender() {}

    public static void main(String[] args) throws Exception {
        String host = args.length > 0 ? args[0] : AppleNativeBridge.DEFAULT_HOST;
        int port = args.length > 1 ? Integer.parseInt(args[1]) : AppleNativeBridge.DEFAULT_PORT;
        // 3rd arg = frame count; <= 0 (default) streams continuously until Ctrl-C.
        long maxFrames = args.length > 2 ? Long.parseLong(args[2]) : 0;

        System.out.println("VisionCraft test-pattern sender -> " + host + ":" + port);
        byte[] leftBase = rasterize(checker(Color.RED, Color.BLACK));
        byte[] rightBase = rasterize(checker(Color.BLUE, Color.DARK_GRAY));

        AtomicLong poses = new AtomicLong();
        long frameId = 0;
        long attempts = 0;
        long start = System.nanoTime();

        while (maxFrames <= 0 || frameId < maxFrames) {
            attempts++;
            AtomicBoolean poseLogging = new AtomicBoolean(false);
            Thread poseLogger = null;
            try (AppleNativeBridge bridge = new AppleNativeBridge(host, port)) {
                bridge.connectWithRetry(60, 250);
                waitForSession(bridge, 30_000);

                poseLogging.set(true);
                poseLogger = new Thread(() -> logPoses(bridge, poses, poseLogging), "pose-logger");
                poseLogger.setDaemon(true);
                poseLogger.start();

                while (maxFrames <= 0 || frameId < maxFrames) {
                    if (!bridge.isConnected()) {
                        System.out.println("Bridge disconnected; reconnecting");
                        break;
                    }
                    if (bridge.getSessionState() != AppleNativeBridge.SessionState.READY) {
                        Thread.sleep(50);
                        continue;
                    }

                    frameId++;
                    int framePhase = (int) (frameId & 0x7fffffff);
                    byte[] left = tint(leftBase, framePhase, 0);
                    byte[] right = tint(rightBase, framePhase, 40);
                    long t0 = System.nanoTime();
                    bridge.sendFrame(new AppleNativeBridge.FramePacket(
                        frameId,
                        t0,
                        WIDTH, HEIGHT, left,
                        WIDTH, HEIGHT, right,
                        0.05f, 512f,
                        null
                    ));
                    long sendMs = (System.nanoTime() - t0) / 1_000_000;
                    if (frameId % 30 == 0) {
                        System.out.printf("frame %d send=%d ms poses=%d%n", frameId, sendMs, poses.get());
                    }
                    Thread.sleep(FRAME_INTERVAL_MS);
                }
            } catch (IOException e) {
                System.out.printf("Bridge send/connect failed on attempt %d: %s%n", attempts, e.getMessage());
                Thread.sleep(250);
            } finally {
                stopPoseLogger(poseLogging, poseLogger);
            }
        }

        long elapsedMs = (System.nanoTime() - start) / 1_000_000;
        System.out.printf("Done. %d frames in %d ms (poses seen: %d)%n", frameId, elapsedMs, poses.get());
    }

    private static void waitForSession(AppleNativeBridge bridge, long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (bridge.getSessionState() == AppleNativeBridge.SessionState.READY) {
                System.out.println("Session ready");
                return;
            }
            Thread.sleep(100);
        }
        System.out.println("Warning: session not ready - start VisionCraftHost immersive space");
    }

    private static void logPoses(AppleNativeBridge bridge, AtomicLong count, AtomicBoolean running) {
        int lastRecenter = -1;
        while (running.get() && !Thread.currentThread().isInterrupted()) {
            AppleNativeBridge.Pose p = bridge.getLatestPose();
            if (p.timestampNs() > 0) {
                count.incrementAndGet();
                if (p.recenterCounter() != lastRecenter) {
                    lastRecenter = p.recenterCounter();
                    System.out.println("recenter_counter=" + lastRecenter);
                }
            }
            try {
                Thread.sleep(500);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
    }

    private static void stopPoseLogger(AtomicBoolean running, Thread poseLogger) throws InterruptedException {
        running.set(false);
        if (poseLogger == null) {
            return;
        }
        poseLogger.interrupt();
        poseLogger.join(1_000);
    }

    private static BufferedImage checker(Color a, Color b) {
        BufferedImage img = new BufferedImage(WIDTH, HEIGHT, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        int cell = 64;
        for (int y = 0; y < HEIGHT; y += cell) {
            for (int x = 0; x < WIDTH; x += cell) {
                boolean even = ((x / cell) + (y / cell)) % 2 == 0;
                g.setColor(even ? a : b);
                g.fillRect(x, y, cell, cell);
            }
        }
        g.dispose();
        return img;
    }

    private static byte[] rasterize(BufferedImage img) {
        byte[] rgba = new byte[WIDTH * HEIGHT * 4];
        int i = 0;
        for (int y = 0; y < HEIGHT; y++) {
            for (int x = 0; x < WIDTH; x++) {
                int argb = img.getRGB(x, y);
                rgba[i++] = (byte) ((argb >> 16) & 0xFF);
                rgba[i++] = (byte) ((argb >> 8) & 0xFF);
                rgba[i++] = (byte) (argb & 0xFF);
                rgba[i++] = (byte) ((argb >> 24) & 0xFF);
            }
        }
        return rgba;
    }

    private static byte[] tint(byte[] base, int frame, int phase) {
        byte[] out = base.clone();
        int shift = ((frame + phase) % 256);
        for (int i = 0; i < out.length; i += 4) {
            out[i] = (byte) (out[i] ^ (shift & 0x1F));
        }
        return out;
    }
}
