package ru.mangapad.legacy;

import java.util.*;
import java.io.File;

/** Owns decoded pages and tracks disk originals. UI thread access only. */
final class PageBuffer<T> {
    interface Disposal<T> { void release(T value); }
    private static final int FORWARD = 5, HISTORY = 2;
    private final long budget;
    private final Disposal<T> disposal;
    private final Map<Integer, Entry<T>> entries = new HashMap<Integer, Entry<T>>();
    private final Map<Integer, File> sources = new HashMap<Integer, File>();
    private long used;
    private int current, count;

    private static final class Entry<T> {
        final T value;
        final long bytes;
        Entry(T value, long bytes) { this.value = value; this.bytes = bytes; }
    }

    PageBuffer(long budget, Disposal<T> disposal) {
        this.budget = Math.max(1, budget); this.disposal = disposal;
    }
    T get(int index) { Entry<T> entry = entries.get(index); return entry == null ? null : entry.value; }
    int forwardLimit() { return Math.min(FORWARD, Math.max(0, count - current)); }
    int forwardCount() {
        int total = 0;
        for (int index = current; index < current + forwardLimit(); index++) if (ready(index)) total++;
        return total;
    }
    int historyCount() {
        int total = 0;
        for (int index = Math.max(0, current - HISTORY); index < current; index++) if (ready(index)) total++;
        return total;
    }
    void rememberSource(int index, File source) {
        if (source != null && index >= Math.max(0, current - HISTORY)
                && index < current + forwardLimit()) sources.put(index, source);
    }
    private boolean ready(int index) {
        if (entries.containsKey(index)) return true;
        File source = sources.get(index);
        if (source == null) return false;
        long bytes = source.length();
        if (bytes > 0 && bytes <= 12L * 1024 * 1024 && source.isFile()) return true;
        sources.remove(index); return false;
    }
    int nextPrefetch(Set<Integer> failed) {
        for (int index = current + 1; index < current + forwardLimit(); index++) {
            if (!ready(index) && !failed.contains(Integer.valueOf(index))) return index;
        }
        return -1;
    }
    long estimatedPageBytes() {
        long estimate = 1;
        for (Entry<T> entry : entries.values()) estimate = Math.max(estimate, entry.bytes);
        return estimate;
    }
    boolean hasRoom(long bytes) { return bytes > 0 && bytes <= budget - used; }
    void show(int index, int pageCount, T value, long bytes) {
        current = index; count = pageCount;
        // The view must switch to value before this method disposes old pages.
        for (int key : new ArrayList<Integer>(entries.keySet())) {
            if (key < Math.max(0, current - HISTORY) || key >= current + forwardLimit()) remove(key);
        }
        for (int key : new ArrayList<Integer>(sources.keySet())) {
            if (key < Math.max(0, current - HISTORY) || key >= current + forwardLimit()) sources.remove(key);
        }
        if (get(index) != value) {
            remove(index);
            entries.put(index, new Entry<T>(value, bytes)); used += bytes;
        }
        while (used > budget && entries.size() > 1) {
            int farthest = current;
            for (int key : entries.keySet()) {
                if (Math.abs(key - current) > Math.abs(farthest - current)) farthest = key;
            }
            remove(farthest);
        }
    }
    boolean offer(int index, T value, long bytes) {
        if (index <= current || index >= current + forwardLimit() || get(index) != null || !hasRoom(bytes)) {
            disposal.release(value); return false;
        }
        entries.put(index, new Entry<T>(value, bytes)); used += bytes; return true;
    }
    void keepCurrent() {
        for (int key : new ArrayList<Integer>(entries.keySet())) if (key != current) remove(key);
    }
    void clear() {
        for (int key : new ArrayList<Integer>(entries.keySet())) remove(key);
        sources.clear();
        current = count = 0;
    }
    private void remove(int index) {
        Entry<T> entry = entries.remove(index);
        if (entry != null) { used -= entry.bytes; disposal.release(entry.value); }
    }
}
