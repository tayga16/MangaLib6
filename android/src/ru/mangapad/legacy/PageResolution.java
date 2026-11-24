package ru.mangapad.legacy;

/** Keep source detail until the bitmap memory budget requires downsampling. */
final class PageResolution {
    static long pagePixels(long heap, boolean jpeg) {
        // JPEG has no alpha and RGB_565 really uses two bytes per pixel.
        // PNG/GIF can force ARGB_8888, so keep their four-byte reservation.
        return Math.max(1, Math.min(10L * 1024 * 1024, heap / 4) / (jpeg ? 2 : 4));
    }
    static int sampleSize(int width, int height, long pixels) {
        int sample = 1;
        pixels = Math.max(1, pixels);
        while (area(width, height, sample) > pixels && sample < (1 << 30)) sample *= 2;
        return sample;
    }
    static int detailSample(int sourceWidth, int sourceHeight, int regionWidth, int regionHeight,
            float displayWidth, float displayHeight, long pixels) {
        int displaySample = 1;
        // Decode enough detail for this zoom instead of immediately reducing it.
        while (displaySample < (1 << 30) && sourceWidth / (displaySample * 2L) >= displayWidth
                && sourceHeight / (displaySample * 2L) >= displayHeight) displaySample *= 2;
        return Math.max(displaySample, sampleSize(regionWidth, regionHeight, pixels));
    }
    private static long area(int width, int height, int sample) {
        return ((Math.max(1, width) + (long)sample - 1) / sample)
            * ((Math.max(1, height) + (long)sample - 1) / sample);
    }
}
