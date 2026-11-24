package ru.mangapad.legacy;

import java.io.*;
import java.util.Arrays;

public final class PageQualityCheck {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static byte[] read(File file) throws IOException {
        FileInputStream input = new FileInputStream(file);
        try {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] block = new byte[256]; int size;
            while ((size = input.read(block)) != -1) output.write(block, 0, size);
            return output.toByteArray();
        } finally { input.close(); }
    }
    public static void main(String[] args) throws Exception {
        long htcHeap = 20L * 1024 * 1024;
        check(PageResolution.sampleSize(1970, 2800, PageResolution.pagePixels(htcHeap, true)) == 2,
            "HTC JPEG is already sharp at double-tap zoom before any region decode");
        check(PageResolution.sampleSize(1425, 2048, PageResolution.pagePixels(htcHeap, true)) == 2,
            "larger original respects HTC's bitmap byte budget");
        check(PageResolution.sampleSize(1000, 1400, PageResolution.pagePixels(htcHeap, true)) == 1,
            "ordinary JPEG keeps every source pixel on HTC");
        check(PageResolution.pagePixels(htcHeap, false) * 4 <= htcHeap / 4,
            "transparent images retain ARGB memory reservation");
        check(PageResolution.sampleSize(1000, 1400, 1500000) == 1,
            "ordinary source keeps text detail regardless of a 320x480 screen");
        check(PageResolution.sampleSize(1200, 1800, 1500000) == 2, "memory budget requires sampling");
        check(PageResolution.detailSample(4096, 6144, 1024, 1536, 1024, 1536, 1000000) == 4,
            "detail matches display pixels instead of decoding a full-resolution crop");
        check(PageResolution.detailSample(4096, 6144, 1024, 1536, 2048, 3072, 1000000) == 2,
            "zooming further reveals a finer sample");
        check(PageResolution.detailSample(4096, 6144, 1024, 1536, 8192, 12288, 2000000) == 1,
            "maximum zoom retains original pixels");
        check(PageResolution.detailSample(4096, 6144, 1024, 1536, 8192, 12288, 100000) == 4,
            "small Dalvik heap bounds the crop even at maximum zoom");
        check(PageResolution.detailSample(1001, 1501, 501, 751, 501, 751, 1000000) == 1,
            "odd source dimensions do not undersample text at screen density");
        for (int[] dimensions : new int[][] { {1200, 50000}, {50000, 1200},
                {Integer.MAX_VALUE, Integer.MAX_VALUE}, {1, Integer.MAX_VALUE}, {1001, 1501} }) {
            long pixels = 1000000;
            int sample = PageResolution.sampleSize(dimensions[0], dimensions[1], pixels);
            long width = (dimensions[0] + (long)sample - 1) / sample;
            long height = (dimensions[1] + (long)sample - 1) / sample;
            check((sample & (sample - 1)) == 0, "power-of-two legacy decoder sampling");
            check(width * height <= pixels, "huge or odd-size source stays inside bitmap budget");
            int detailSample = PageResolution.detailSample(dimensions[0], dimensions[1],
                dimensions[0], dimensions[1], 320, 480, pixels);
            check((detailSample & (detailSample - 1)) == 0, "detail sampling stays power-of-two");
            check(((dimensions[0] + (long)detailSample - 1) / detailSample)
                * ((dimensions[1] + (long)detailSample - 1) / detailSample) <= pixels,
                "detail sampling respects budget with extreme dimensions");
        }
        File root = new File(args[0]);
        check(root.mkdirs(), "isolated cache directory");
        PageSources sources = new PageSources(root, 12);
        byte[] original = new byte[] {(byte)255, (byte)216, 1, 2, 3, 4, 5, 6};
        sources.put("chapter/page1", original);
        File pinned = sources.file("chapter/page1"); sources.pin(pinned);
        check(Arrays.equals(read(pinned), original), "zoom cache preserves encoded original bytes");
        check(Arrays.equals(sources.read("chapter/page1"), original), "reopening a cached page uses original bytes offline");
        check(sources.read("missing") == null, "missing source falls back to download");
        check(!sources.file("../outside").getName().contains(".."), "URL cannot escape cache root");
        sources.put("chapter/page2", original);
        sources.put("chapter/page3", original);
        check(pinned.isFile(), "prefetch cannot evict current page source");
        check(!sources.file("chapter/page2").exists(), "older unpinned source evicted first");
        check(sources.file("chapter/page3").isFile(), "new source available for decoding");
        sources.pin(null); sources.put("chapter/page4", original);
        check(!pinned.exists(), "released page can be evicted");
        long size = 0;
        for (File file : root.listFiles()) { check(file.getName().endsWith(".image"), "temporary file cleaned"); size += file.length(); }
        check(size <= 12, "cache bounded after pin release");
        File blocked = new File(root, "blocked");
        check(blocked.createNewFile(), "unusable cache fixture");
        try { new PageSources(blocked, 12).put("page", original); throw new AssertionError("disk failure hidden"); }
        catch (IOException expected) { }
        System.out.println("PASS: source resolution, overflow-safe memory limits, original cache and pinned eviction");
    }
}
