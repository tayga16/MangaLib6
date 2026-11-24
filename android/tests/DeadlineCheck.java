package ru.mangapad.legacy;

import java.io.IOException;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Simulate an emulator whose native Socket.close() stalls. */
public final class DeadlineCheck {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    public static void main(String[] args) throws Exception {
        final CountDownLatch releasedClosed = new CountDownLatch(1);
        Socket reusable = new Socket() { public void close() { releasedClosed.countDown(); } };
        RequestDeadline released = new RequestDeadline(10000);
        released.attach(reusable);
        check(released.release(reusable), "live socket release failed");
        released.cancel();
        check(!releasedClosed.await(150, TimeUnit.MILLISECONDS), "old deadline closed released connection");
        RequestDeadline stopped = new RequestDeadline(10000);
        stopped.attach(reusable); stopped.cancel();
        check(!stopped.release(reusable), "cancelled socket released into pool");
        check(releasedClosed.await(2, TimeUnit.SECONDS), "cancelled socket not closed");
        final CountDownLatch closing = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final CountDownLatch closed = new CountDownLatch(1);
        final CountDownLatch nextClosed = new CountDownLatch(1);
        RequestDeadline request = new RequestDeadline(10000);
        RequestDeadline next = null;
        try {
            request.attach(new Socket() { public void close() throws IOException {
                closing.countDown();
                try { release.await(); }
                catch (InterruptedException error) { Thread.currentThread().interrupt(); }
                finally { closed.countDown(); }
            } });
            long start = System.nanoTime();
            request.cancel();
            check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 250,
                "UI cancellation waited for Socket.close()");
            check(closing.await(2, TimeUnit.SECONDS), "background cleanup did not start");
            check(closed.getCount() == 1, "fixture socket must still be blocked");
            next = new RequestDeadline(200);
            next.attach(new Socket() { public void close() { nextClosed.countDown(); } });
            Thread.sleep(350);
            try { next.remainingMillis(); throw new AssertionError("next deadline did not expire"); }
            catch (SocketTimeoutException expected) { }
            check(nextClosed.await(2, TimeUnit.SECONDS), "other socket cleanup blocked behind old request");
            start = System.nanoTime();
            next.cancel();
            check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 250,
                "next cancellation blocked");
            System.out.println("PASS: atomic release rejects cancelled sockets; cancellation returns while Socket.close() is stalled; other deadlines expire");
        } finally {
            release.countDown(); request.cancel(); if (next != null) next.cancel();
        }
        check(closed.await(2, TimeUnit.SECONDS), "socket was not closed after release");
    }
}
