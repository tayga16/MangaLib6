package ru.mangapad.legacy;

import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;

/** A monotonic deadline for the entire operation, including DNS and slow responses. */
final class RequestDeadline {
    private static final ThreadLocal<RequestDeadline> CURRENT = new ThreadLocal<RequestDeadline>();
    private static final ThreadFactory DAEMON = new ThreadFactory() {
        public Thread newThread(Runnable task) {
            Thread thread = new Thread(task, "mangalib-network-clock");
            thread.setDaemon(true);
            return thread;
        }
    };
    private static final ScheduledExecutorService CLOCK = Executors.newSingleThreadScheduledExecutor(DAEMON);
    // Socket.close() can wait for a native network lock on old Android runtimes.
    // Never run it on the UI thread or the deadline clock itself.
    private static final ExecutorService CLEANUP = Executors.newFixedThreadPool(2, DAEMON);
    // A stuck platform resolver must not occupy the application's request queue.
    // Bound resolver threads and pending lookups even if Android ignores interruption.
    private static final ExecutorService DNS = new ThreadPoolExecutor(2, 2, 30, TimeUnit.SECONDS,
        new ArrayBlockingQueue<Runnable>(2), DAEMON);
    private final long end;
    private final List<Socket> sockets = new ArrayList<Socket>();
    private final ScheduledFuture<?> alarm;
    private boolean expired, cancelled;

    RequestDeadline(long milliseconds) {
        end = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(milliseconds);
        alarm = CLOCK.schedule(new Runnable() { public void run() { stop(true); } },
            milliseconds, TimeUnit.MILLISECONDS);
    }
    static RequestDeadline current() { return CURRENT.get(); }
    static void enter(RequestDeadline deadline) { CURRENT.set(deadline); }
    static void leave() { CURRENT.remove(); }
    synchronized int remainingMillis() throws IOException {
        if (cancelled || Thread.currentThread().isInterrupted()) throw new InterruptedIOException("Загрузка отменена");
        long remaining = end - System.nanoTime();
        if (expired || remaining <= 0) throw new SocketTimeoutException("Истекло время ожидания ответа");
        return (int)Math.min(Integer.MAX_VALUE, Math.max(1, TimeUnit.NANOSECONDS.toMillis(remaining)));
    }
    synchronized void attach(Socket socket) throws IOException {
        remainingMillis();
        sockets.add(socket);
    }
    synchronized void detach(Socket socket) { sockets.remove(socket); }
    // Atomically detach only while this operation still owns a live socket.
    // A cancelled deadline may already have queued it for asynchronous closure.
    synchronized boolean release(Socket socket) {
        boolean owned = sockets.remove(socket);
        try { remainingMillis(); return owned; }
        catch (IOException stopped) { return false; }
    }
    static void closeSocket(final Socket socket) {
        CLEANUP.execute(new Runnable() { public void run() {
            try { socket.close(); } catch (IOException ignored) { }
        } });
    }
    void cancel() { alarm.cancel(false); stop(false); }
    private void stop(boolean timeout) {
        final List<Socket> close;
        synchronized (this) {
            if (expired || cancelled) return;
            expired = timeout;
            cancelled = !timeout;
            close = new ArrayList<Socket>(sockets);
            sockets.clear();
        }
        if (!close.isEmpty()) CLEANUP.execute(new Runnable() { public void run() {
            for (Socket socket : close) try { socket.close(); } catch (IOException ignored) { }
        } });
    }
    InetAddress resolve(final String host) throws IOException {
        Future<InetAddress> lookup;
        try { lookup = DNS.submit(new Callable<InetAddress>() {
            public InetAddress call() throws UnknownHostException { return InetAddress.getByName(host); }
        }); }
        catch (RejectedExecutionException error) { throw new IOException("DNS занят. Повтори загрузку позже."); }
        try { return lookup.get(remainingMillis(), TimeUnit.MILLISECONDS); }
        catch (TimeoutException error) { throw new SocketTimeoutException("DNS не ответил вовремя: " + host); }
        catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new InterruptedIOException("Загрузка отменена");
        }
        catch (ExecutionException error) {
            Throwable cause = error.getCause();
            if (cause instanceof IOException) throw (IOException)cause;
            throw new IOException("Не удалось найти сервер: " + host, cause);
        }
        finally { lookup.cancel(true); }
    }
}
