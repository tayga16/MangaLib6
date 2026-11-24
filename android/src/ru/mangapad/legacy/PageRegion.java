package ru.mangapad.legacy;

import android.graphics.*;
import java.io.*;

/** Isolate the API 10 decoder so API 9 keeps using the full-page preview. */
final class PageRegion implements PageView.RegionDecoder {
    private final BitmapRegionDecoder decoder;
    private PageRegion(File source) throws IOException {
        decoder = BitmapRegionDecoder.newInstance(source.getAbsolutePath(), false);
        if (decoder == null) throw new IOException("Не удалось открыть исходник страницы");
    }
    static PageView.RegionDecoder open(File source) throws IOException { return new PageRegion(source); }
    public void close() { decoder.recycle(); }
    public PageView.Detail decode(RectF visible, long pixels, int previewWidth, int previewHeight,
            float displayWidth, float displayHeight) throws IOException {
        int width = decoder.getWidth(), height = decoder.getHeight();
        Rect region = new Rect(Math.max(0, (int)Math.floor(visible.left * width)),
            Math.max(0, (int)Math.floor(visible.top * height)),
            Math.min(width, (int)Math.ceil(visible.right * width)),
            Math.min(height, (int)Math.ceil(visible.bottom * height)));
        if (region.width() <= 0 || region.height() <= 0) return null;
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inPreferredConfig = Bitmap.Config.RGB_565;
        options.inSampleSize = PageResolution.detailSample(width, height, region.width(), region.height(),
            displayWidth, displayHeight, pixels);
        // Never cover a sharper full-page preview with a lower-resolution region.
        if ((long)previewWidth * options.inSampleSize >= width
                && (long)previewHeight * options.inSampleSize >= height) return null;
        Bitmap image = decoder.decodeRegion(region, options);
        if (image == null) throw new IOException("Не удалось увеличить страницу");
        return new PageView.Detail(image, new RectF((float)region.left / width,
            (float)region.top / height, (float)region.right / width, (float)region.bottom / height),
            width, height, options.inSampleSize);
    }
}
