package ru.mangapad.legacy;

import java.util.*;
import java.io.File;

/** Verify bitmap ownership and memory pressure without an Android runtime. */
public final class PageBufferCheck {
    private static final class Page { boolean released; }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    private static PageBuffer<Page> buffer(long budget) {
        return new PageBuffer<Page>(budget, new PageBuffer.Disposal<Page>() { public void release(Page page) {
            check(!page.released, "Page released twice"); page.released = true;
        } });
    }
    public static void main(String[] args) throws Exception {
        PageBuffer<Page> buffer = buffer(700);
        Page first = new Page(); buffer.show(0, 10, first, 100);
        Page[] forward = new Page[4];
        for (int i = 0; i < 4; i++) { forward[i] = new Page(); check(buffer.offer(i + 1, forward[i], 100), "Prefetch rejected"); }
        check(buffer.forwardCount() == 5 && buffer.historyCount() == 0, "Initial count");
        Page outside = new Page(); check(!buffer.offer(5, outside, 100) && outside.released, "Out-of-window leak");
        buffer.show(2, 10, forward[1], 100);
        check(buffer.get(0) == first && !first.released && buffer.historyCount() == 2, "Backward buffer lost");
        buffer.show(3, 10, forward[2], 100);
        check(first.released && !forward[0].released && buffer.historyCount() == 2, "History bound");
        buffer.show(2, 10, forward[1], 100);
        check(!forward[1].released && buffer.forwardCount() == 3 && buffer.historyCount() == 1, "Back navigation");
        buffer.keepCurrent();
        check(!forward[1].released && forward[0].released && forward[2].released && forward[3].released, "Memory warning");
        buffer.clear(); check(forward[1].released && buffer.forwardCount() == 0, "Chapter reset");
        buffer.clear();

        buffer = buffer(200); first = new Page(); buffer.show(0, 3, first, 100);
        Page second = new Page(); check(buffer.offer(1, second, 100), "Budget fill");
        Page rejected = new Page(); check(!buffer.offer(2, rejected, 100) && rejected.released, "Memory limit");
        Page large = new Page(); buffer.show(2, 3, large, 300);
        check(first.released && second.released && !large.released, "Current page evicted under pressure");
        check(buffer.forwardLimit() == 1 && buffer.forwardCount() == 1 && !buffer.hasRoom(1), "End-of-chapter bound");
        buffer.clear(); check(large.released, "Current leaked on exit");

        // HTC's sharper JPEG alone uses more than half the 5 MiB RAM budget.
        // Still fetch four originals, and decode them only when needed.
        buffer = buffer(5L * 1024 * 1024);
        long sharpBytes = 2758000;
        first = new Page(); buffer.show(0, 10, first, sharpBytes);
        check(!buffer.hasRoom(sharpBytes), "HTC regression requires a full decoded buffer");
        Set<Integer> failed = new HashSet<Integer>();
        File[] originals = new File[5];
        try {
            for (int i = 0; i < originals.length; i++) {
                originals[i] = File.createTempFile("manga-buffer-", ".image");
                java.io.FileOutputStream output = new java.io.FileOutputStream(originals[i]);
                try { output.write(1); } finally { output.close(); }
            }
            buffer.rememberSource(0, originals[0]);
            for (int i = 1; i <= 4; i++) {
                check(buffer.nextPrefetch(failed) == i, "full RAM must not stop disk prefetch");
                buffer.rememberSource(i, originals[i]);
            }
            check(buffer.forwardCount() == 5 && buffer.nextPrefetch(failed) == -1,
                "disk originals count as ready without repeated downloads");
            buffer.keepCurrent();
            check(buffer.forwardCount() == 5 && !first.released, "memory warning preserves disk buffer");
            second = new Page(); buffer.show(1, 10, second, sharpBytes);
            check(first.released && !second.released && buffer.historyCount() == 1,
                "forward navigation releases old bitmap but retains original for back navigation");
            check(buffer.nextPrefetch(failed) == 5, "moving ahead prefetches the new edge");
            check(originals[3].delete(), "simulate cache eviction");
            check(buffer.nextPrefetch(failed) == 3 && buffer.forwardCount() == 3,
                "evicted source must be downloaded again and removed from counters");
            failed.add(Integer.valueOf(3));
            check(buffer.nextPrefetch(failed) == 5, "failed page must not spin or block later pages");
            buffer.clear();
            Page fresh = new Page(); buffer.show(0, 3, fresh, sharpBytes);
            check(buffer.forwardCount() == 1 && buffer.nextPrefetch(new HashSet<Integer>()) == 1,
                "chapter reset drops old source mappings");
            buffer.clear();
        } finally { for (File original : originals) if (original != null) original.delete(); }
        System.out.println("PASS: decoded/disk prefetch, HTC sharp-page memory limit, cache eviction, navigation, disposal");
    }
}
