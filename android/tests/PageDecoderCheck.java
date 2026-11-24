package ru.mangapad.legacy;

import java.io.*;
import java.util.concurrent.*;

/** Exercise reader ownership during consecutive pans, retirement and cancellation. */
public final class PageDecoderCheck {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static final class Reader { volatile boolean closed; }
    private static final class Factory implements PageDecoder.Factory<Reader> {
        int opens, closes;
        public Reader open(File file) { opens++; return new Reader(); }
        public void close(Reader reader) {
            check(!reader.closed, "reader recycled twice"); reader.closed = true; closes++;
        }
    }
    public static void main(String[] args) throws Exception {
        final Factory factory = new Factory();
        final PageDecoder<Reader> source = new PageDecoder<Reader>(new File("page"), factory);
        PageDecoder.Operation<Reader, Reader> identity = new PageDecoder.Operation<Reader, Reader>() {
            public Reader decode(Reader reader) { check(!reader.closed, "decode uses live reader"); return reader; }
        };
        Reader first = source.decode(identity);
        check(first == source.decode(identity) && factory.opens == 1,
            "consecutive pans open the encoded source only once");
        try {
            source.decode(new PageDecoder.Operation<Reader, Reader>() {
                public Reader decode(Reader reader) throws IOException { throw new IOException("unsupported crop"); }
            });
            throw new AssertionError("decode error hidden");
        } catch (IOException expected) { }
        check(source.decode(identity) == first, "decode failure leaves source usable");

        final CountDownLatch entered = new CountDownLatch(1), finish = new CountDownLatch(1);
        ExecutorService worker = Executors.newSingleThreadExecutor();
        try {
            Future<Reader> pending = worker.submit(new Callable<Reader>() { public Reader call() throws Exception {
                return source.decode(new PageDecoder.Operation<Reader, Reader>() {
                    public Reader decode(Reader reader) throws IOException {
                        entered.countDown();
                        try { check(finish.await(3, TimeUnit.SECONDS), "decode fixture released"); }
                        catch (InterruptedException error) { throw new IOException(error); }
                        check(!reader.closed, "retirement cannot recycle during native decode");
                        return reader;
                    }
                });
            } });
            check(entered.await(3, TimeUnit.SECONDS), "background decode started");
            source.retire();
            check(!pending.isDone() && !first.closed, "UI retirement returns while decode is active");
            finish.countDown();
            check(pending.get(3, TimeUnit.SECONDS) == first && first.closed && factory.closes == 1,
                "reader recycled when the in-flight decode finishes");
            source.close(); source.close();
            check(source.decode(identity) == null && factory.opens == 1 && factory.closes == 1,
                "retired source cannot reopen and cleanup is idempotent");
        } finally { finish.countDown(); worker.shutdownNow(); }

        Factory cancelledFactory = new Factory();
        PageDecoder<Reader> cancelled = new PageDecoder<Reader>(new File("next"), cancelledFactory);
        Thread.currentThread().interrupt();
        try { check(cancelled.decode(identity) == null && cancelledFactory.opens == 0,
            "cancelled task cannot open a native reader"); }
        finally { Thread.interrupted(); }
        cancelled.retire(); cancelled.close();
        check(cancelledFactory.closes == 0, "unopened source has nothing to recycle");
        System.out.println("PASS: decoder reuse, failure recovery, nonblocking retirement, safe recycling and cancellation");
    }
}
