package ru.mangapad.legacy;

import java.io.File;
import java.io.IOException;

/** Reuse one reader per page; retiring it never waits for a native decode. */
final class PageDecoder<T> {
    interface Factory<T> { T open(File file) throws IOException; void close(T reader); }
    interface Operation<T, R> { R decode(T reader) throws IOException; }
    private final File file;
    private final Factory<T> factory;
    private T reader;
    volatile boolean retired;

    PageDecoder(File file, Factory<T> factory) { this.file = file; this.factory = factory; }
    synchronized <R> R decode(Operation<T, R> operation) throws IOException {
        if (retired || Thread.currentThread().isInterrupted()) return null;
        try {
            if (reader == null) reader = factory.open(file);
            return operation.decode(reader);
        } finally { if (retired) close(); }
    }
    void retire() { retired = true; }
    synchronized void close() {
        if (reader != null) {
            T previous = reader; reader = null;
            factory.close(previous);
        }
    }
}
