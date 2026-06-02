package visioncraft.bridge;

import java.io.IOException;
import java.util.ArrayDeque;
import java.util.Deque;

/**
 * Sends stereo eye frames to the host on a dedicated thread so the render thread
 * never blocks on socket I/O.
 *
 * <p><b>Latest-frame-wins.</b> If a new frame is committed while one is still queued
 * waiting to be sent, the older queued frame is dropped (recycled). End-to-end latency
 * therefore stays bounded under backpressure instead of accumulating a send backlog —
 * the headset always shows the freshest frame the renderer produced.
 *
 * <p><b>Pooled buffers.</b> Pixel buffers are recycled through a small fixed pool so the
 * hot path performs no per-frame heap allocation (the dominant GC-churn source when
 * shovelling ~10&nbsp;MB/eye every frame at 72–90&nbsp;Hz).
 *
 * <p><b>Threading.</b> {@link #beginFrame(int, int)}, {@link #commitFrame} and
 * {@link #abandon} run on the render thread; {@code runLoop} runs on its own daemon
 * thread. The pool deque and the single-slot mailbox ({@code pending}) are guarded by
 * {@code lock}. A {@link Frame} returned by {@code beginFrame} is owned exclusively by
 * the render thread until it is committed/abandoned, and exclusively by the sender thread
 * while it is being sent, so the pixel arrays are never touched by two threads at once.
 */
public final class AsyncFrameSender implements AutoCloseable {

    /**
     * Consumes one frame, synchronously, on the sender thread. Implementations must finish
     * reading the frame's pixel arrays before returning (the buffers are recycled afterwards).
     */
    @FunctionalInterface
    public interface FrameSink {
        void send(Frame frame) throws IOException;
    }

    /** Mutable, pooled holder for one stereo frame's pixel buffers and metadata. */
    public static final class Frame {
        private static final byte[] EMPTY = new byte[0];

        private byte[] left = EMPTY;
        private byte[] right = EMPTY;
        private int width;
        private int height;
        private long frameId;
        private long timestampNs;
        private float near;
        private float far;
        private long copyTimeNs;
        private float[] renderOrientationXyzw;

        /** Left-eye RGBA8 backing array, sized {@code width*height*4}. Fill in place. */
        public byte[] left() {
            return left;
        }

        /** Right-eye RGBA8 backing array, sized {@code width*height*4}. Fill in place. */
        public byte[] right() {
            return right;
        }

        public int width() {
            return width;
        }

        public int height() {
            return height;
        }

        public long frameId() {
            return frameId;
        }

        public long timestampNs() {
            return timestampNs;
        }

        public float near() {
            return near;
        }

        public float far() {
            return far;
        }

        /** Producer-measured GPU→CPU copy time for this frame, carried to the sink for metrics. */
        public long copyTimeNs() {
            return copyTimeNs;
        }

        public void setCopyTimeNs(long ns) {
            this.copyTimeNs = ns;
        }

        /** Head orientation (ARKit world, xyzw) the frame was rendered for, or {@code null}. */
        public float[] renderOrientationXyzw() {
            return renderOrientationXyzw;
        }

        private void resize(int w, int h) {
            this.width = w;
            this.height = h;
            int bytes = Math.max(0, w) * Math.max(0, h) * 4;
            if (left.length != bytes) {
                left = new byte[bytes];
            }
            if (right.length != bytes) {
                right = new byte[bytes];
            }
        }
    }

    /** One being filled + one queued + one in flight = 3 keeps the render thread allocation-free. */
    private static final int POOL_SIZE = 3;

    private final FrameSink sink;
    private final Object lock = new Object();
    private final Deque<Frame> free = new ArrayDeque<>(POOL_SIZE);
    private final Thread thread;

    private Frame pending;
    private boolean running = true;
    private long droppedFrames;
    private long sentFrames;

    public AsyncFrameSender(FrameSink sink) {
        this.sink = sink;
        for (int i = 0; i < POOL_SIZE; i++) {
            free.add(new Frame());
        }
        this.thread = new Thread(this::runLoop, "visioncraft-frame-sender");
        this.thread.setDaemon(true);
        this.thread.start();
    }

    /**
     * Acquire a pooled frame whose eye buffers are sized to {@code width*height*4}.
     * Never blocks and never returns {@code null} — the pool is sized so a single render
     * thread always has a free slot; under (unexpected) exhaustion a spare is allocated
     * rather than stalling rendering. The caller owns the frame until it is passed to
     * {@link #commitFrame} or {@link #abandon}.
     */
    public Frame beginFrame(int width, int height) {
        Frame f;
        synchronized (lock) {
            f = free.pollFirst();
        }
        if (f == null) {
            f = new Frame();
        }
        f.resize(width, height);
        return f;
    }

    /**
     * Hand a filled frame to the sender. Latest-wins: any frame still queued (not yet
     * picked up by the sender) is dropped and recycled.
     */
    public void commitFrame(Frame frame, long frameId, long timestampNs, float near, float far,
        float[] renderOrientationXyzw) {
        frame.frameId = frameId;
        frame.timestampNs = timestampNs;
        frame.near = near;
        frame.far = far;
        frame.renderOrientationXyzw = renderOrientationXyzw;
        synchronized (lock) {
            if (!running) {
                recycle(frame);
                return;
            }
            if (pending != null) {
                recycle(pending);
                droppedFrames++;
            }
            pending = frame;
            lock.notifyAll();
        }
    }

    /** Return an acquired frame to the pool without sending (e.g. readback failed). */
    public void abandon(Frame frame) {
        synchronized (lock) {
            recycle(frame);
        }
    }

    private void runLoop() {
        while (true) {
            Frame frame;
            synchronized (lock) {
                while (running && pending == null) {
                    try {
                        lock.wait();
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
                if (pending == null) {
                    return; // closed and drained
                }
                frame = pending;
                pending = null;
            }
            try {
                sink.send(frame);
                synchronized (lock) {
                    sentFrames++;
                }
            } catch (IOException | RuntimeException e) {
                // Drop this frame; the producer gates on session state, so the pipeline
                // self-heals once the host is ready again. Never kill the sender thread.
            } finally {
                synchronized (lock) {
                    recycle(frame);
                }
            }
        }
    }

    /** Caller must hold {@code lock}. Spares allocated under exhaustion are let go (GC'd). */
    private void recycle(Frame f) {
        if (free.size() < POOL_SIZE) {
            free.addLast(f);
        }
    }

    /** Frames committed but dropped before sending due to backpressure (latest-wins). */
    public long droppedFrames() {
        synchronized (lock) {
            return droppedFrames;
        }
    }

    /** Frames successfully handed to the sink. */
    public long sentFrames() {
        synchronized (lock) {
            return sentFrames;
        }
    }

    @Override
    public void close() {
        synchronized (lock) {
            running = false;
            lock.notifyAll();
        }
        thread.interrupt();
        try {
            thread.join(500);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
