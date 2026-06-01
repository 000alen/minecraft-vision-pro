package visioncraft.bridge;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AsyncFrameSenderTest {

    @Test
    void deliversFramesInOrderWithoutBackpressure() throws Exception {
        List<Long> sent = new ArrayList<>();
        CountDownLatch delivered = new CountDownLatch(5);
        try (AsyncFrameSender sender = new AsyncFrameSender(frame -> {
            synchronized (sent) {
                sent.add(frame.frameId());
            }
            delivered.countDown();
        })) {
            for (long i = 1; i <= 5; i++) {
                AsyncFrameSender.Frame f = sender.beginFrame(2, 2);
                sender.commitFrame(f, i, i * 10L, 0.05f, 512f);
                // Wait for this frame to land before producing the next so none are dropped.
                awaitCount(sent, (int) i);
            }
            assertTrue(delivered.await(2, TimeUnit.SECONDS), "all frames delivered");
        }
        assertEquals(List.of(1L, 2L, 3L, 4L, 5L), sent);
    }

    @Test
    void dropsStaleFramesUnderBackpressure() throws Exception {
        List<Long> sent = new ArrayList<>();
        AtomicBoolean firstSend = new AtomicBoolean(true);
        CountDownLatch firstStarted = new CountDownLatch(1);
        CountDownLatch releaseFirst = new CountDownLatch(1);
        CountDownLatch sentTwo = new CountDownLatch(2);

        AsyncFrameSender sender = new AsyncFrameSender(frame -> {
            if (firstSend.compareAndSet(true, false)) {
                firstStarted.countDown();
                try {
                    releaseFirst.await(2, TimeUnit.SECONDS);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
            synchronized (sent) {
                sent.add(frame.frameId());
            }
            sentTwo.countDown();
        });

        // Frame 1 is picked up and blocks inside the sink.
        sender.commitFrame(sender.beginFrame(2, 2), 1L, 0L, 0.05f, 512f);
        assertTrue(firstStarted.await(2, TimeUnit.SECONDS), "first frame entered the sink");

        // While the sender is blocked, queue two more: frame 2 then frame 3.
        // Latest-wins must drop frame 2 and keep frame 3.
        sender.commitFrame(sender.beginFrame(2, 2), 2L, 0L, 0.05f, 512f);
        sender.commitFrame(sender.beginFrame(2, 2), 3L, 0L, 0.05f, 512f);

        releaseFirst.countDown();
        assertTrue(sentTwo.await(2, TimeUnit.SECONDS), "two frames delivered");
        sender.close();

        assertEquals(List.of(1L, 3L), sent, "stale frame 2 dropped, freshest kept");
        assertEquals(1L, sender.droppedFrames());
    }

    @Test
    void recyclesBuffersAcrossManyFramesUnderBackpressure() throws Exception {
        // Hold the sink so committed frames pile up; the pool must keep serving the
        // producer without unbounded growth and without ever returning null.
        CountDownLatch release = new CountDownLatch(1);
        AtomicBoolean blocked = new AtomicBoolean(true);
        CountDownLatch oneStarted = new CountDownLatch(1);
        AsyncFrameSender sender = new AsyncFrameSender(frame -> {
            if (blocked.get()) {
                oneStarted.countDown();
                try {
                    release.await(2, TimeUnit.SECONDS);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        });

        sender.commitFrame(sender.beginFrame(4, 4), 1L, 0L, 0.05f, 512f);
        assertTrue(oneStarted.await(2, TimeUnit.SECONDS));

        for (long i = 2; i <= 1000; i++) {
            AsyncFrameSender.Frame f = sender.beginFrame(4, 4);
            assertNotNull(f, "pool always serves the render thread");
            assertEquals(4 * 4 * 4, f.left().length);
            assertEquals(4 * 4 * 4, f.right().length);
            sender.commitFrame(f, i, 0L, 0.05f, 512f);
        }
        blocked.set(false);
        release.countDown();
        sender.close();

        // 1000 committed, 1 sent (the blocked one), the rest mostly dropped (latest-wins).
        assertTrue(sender.droppedFrames() >= 990,
            "the vast majority of stale frames were dropped, not buffered");
    }

    @Test
    void resizesEyeBuffersWhenDimensionsChange() {
        try (AsyncFrameSender sender = new AsyncFrameSender(frame -> { })) {
            AsyncFrameSender.Frame small = sender.beginFrame(2, 2);
            assertEquals(2 * 2 * 4, small.left().length);
            sender.abandon(small);

            AsyncFrameSender.Frame big = sender.beginFrame(8, 4);
            assertEquals(8 * 4 * 4, big.left().length);
            assertEquals(8 * 4 * 4, big.right().length);
            assertEquals(8, big.width());
            assertEquals(4, big.height());
        }
    }

    @Test
    void commitAfterCloseDoesNotThrow() {
        AsyncFrameSender sender = new AsyncFrameSender(frame -> { });
        AsyncFrameSender.Frame f = sender.beginFrame(2, 2);
        sender.close();
        // Must be a no-op, not an exception or leak.
        sender.commitFrame(f, 1L, 0L, 0.05f, 512f);
        assertFalse(sender.sentFrames() > 1);
    }

    private static void awaitCount(List<Long> list, int target) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (System.nanoTime() < deadline) {
            synchronized (list) {
                if (list.size() >= target) {
                    return;
                }
            }
            Thread.sleep(1);
        }
        throw new AssertionError("timed out waiting for " + target + " frames");
    }
}
