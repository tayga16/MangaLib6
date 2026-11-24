package ru.mangapad.legacy;

import android.app.Instrumentation;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Bundle;
import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/** Isolated on-device view check of the reader sources under the target heap. */
public final class ZoomDeviceCheck extends Instrumentation {
    private PageView view;
    private Bitmap preview;
    private interface MainAction { void run() throws Exception; }
    private void main(final MainAction action) throws Exception {
        final Throwable[] failure = new Throwable[1];
        runOnMainSync(new Runnable() { public void run() {
            try { action.run(); } catch (Throwable error) { failure[0] = error; }
        } });
        if (failure[0] != null) throw new Exception("View check failed", failure[0]);
    }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private Object field(String name) throws Exception {
        Field field = PageView.class.getDeclaredField(name); field.setAccessible(true); return field.get(view);
    }
    private void zoom(float scale) throws Exception {
        Method method = PageView.class.getDeclaredMethod("scaleAt", float.class, float.class, float.class);
        method.setAccessible(true); method.invoke(view, scale, 160f, 240f);
    }
    private Object awaitDetail() throws Exception {
        final Object[] prepared = new Object[1];
        long start = System.nanoTime();
        while ((System.nanoTime() - start) / 1000000 < 10000 && prepared[0] == null) {
            main(new MainAction() { public void run() throws Exception { prepared[0] = field("detail"); } });
            if (prepared[0] == null) Thread.sleep(50);
        }
        check(prepared[0] != null, "sharp centre was not prepared before zoom");
        return prepared[0];
    }
    public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    public void onStart() {
        final Bundle result = new Bundle();
        try {
            final File original = new File("/data/local/tmp/mangalib-page-check.image");
            BitmapFactory.Options bounds = new BitmapFactory.Options(); bounds.inJustDecodeBounds = true;
            BitmapFactory.decodeFile(original.getAbsolutePath(), bounds);
            BitmapFactory.Options options = new BitmapFactory.Options(); options.inPreferredConfig = Bitmap.Config.RGB_565;
            options.inSampleSize = PageResolution.sampleSize(bounds.outWidth, bounds.outHeight,
                PageResolution.pagePixels(Runtime.getRuntime().maxMemory(), "image/jpeg".equals(bounds.outMimeType)));
            final long before = System.nanoTime();
            preview = BitmapFactory.decodeFile(original.getAbsolutePath(), options);
            check(preview != null, "fixture could not be decoded");
            check(preview.getWidth() == 985 && preview.getHeight() == 1400,
                "HTC JPEG must retain enough pixels for ordinary zoom");
            result.putString("heap", String.valueOf(Runtime.getRuntime().maxMemory()));
            result.putString("preview", preview.getWidth() + "x" + preview.getHeight()
                + "; bytes=" + ((long)preview.getRowBytes() * preview.getHeight())
                + "; ms=" + (System.nanoTime() - before) / 1000000);
            main(new MainAction() { public void run() {
                view = new PageView(getTargetContext(), new PageView.Listener() {
                    public void turn(int direction) { } public void tap() { }
                });
                view.layout(0, 0, 320, 480); view.setPage(preview, original);
            } });
            long start = System.nanoTime();
            final Object prepared = awaitDetail();
            result.putString("prepared_ms", String.valueOf((System.nanoTime() - start) / 1000000));
            main(new MainAction() { public void run() throws Exception {
                    PageView.Detail crop = (PageView.Detail)prepared;
                    result.putString("crop", crop.bitmap.getWidth() + "x" + crop.bitmap.getHeight()
                        + "; bytes=" + ((long)crop.bitmap.getRowBytes() * crop.bitmap.getHeight())
                        + "; sample=" + crop.sample);
                    final long zoomStart = System.nanoTime();
                    zoom(4);
                    check(field("detail") == prepared, "zoom must immediately reuse the prepared pixels");
                    check(field("detailTask") == null, "centred zoom must not wait for a new decode");
                    zoom(1);
                    check(field("detail") == prepared, "zoom-out must retain the sharp crop");
                    zoom(4);
                    check(field("detail") == prepared, "repeat zoom must retain the exact bitmap");
                    check(field("detailTask") == null, "repeat zoom must not decode again");
                    result.putString("three_zoom_ms", String.valueOf((System.nanoTime() - zoomStart) / 1000000));
                    Bitmap screen = Bitmap.createBitmap(320, 480, Bitmap.Config.RGB_565);
                    try {
                        android.graphics.Canvas canvas = new android.graphics.Canvas(); canvas.setBitmap(screen);
                        long drawStart = System.nanoTime(); view.draw(canvas);
                        result.putString("draw_ms", String.valueOf((System.nanoTime() - drawStart) / 1000000));
                    } finally { screen.recycle(); }
            } });
            // Gesture during the warm-up must not discard the centre just
            // because the ordinary-zoom viewport extends beyond that crop.
            main(new MainAction() { public void run() throws Exception {
                view.setPage(preview, original); zoom(2.5f);
            } });
            final Object duringZoom = awaitDetail();
            main(new MainAction() { public void run() throws Exception {
                zoom(4);
                check(field("detail") == duringZoom, "ordinary zoom must preserve the prepared centre");
                check(field("detailTask") == null, "stronger zoom must reuse preparation during ordinary zoom");
                PageView.Detail old = (PageView.Detail)duringZoom;
                view.setPage(preview, original);
                check(old.bitmap.isRecycled(), "page replacement must release the previous crop");
                view.releaseDetail();
                check(field("detail") == null && field("detailTask") == null, "low memory must release detail");
            } });
            Thread.sleep(300);
            main(new MainAction() { public void run() throws Exception {
                check(field("detail") == null, "retired preparation must not return after release");
            } });
            result.putString("result", "PASS: immediate prepared/repeated zoom, gesture during preparation, disposal");
        } catch (Throwable error) {
            result.putString("error", error.toString());
        } finally {
            if (view != null) runOnMainSync(new Runnable() { public void run() { view.release(); } });
            if (preview != null) preview.recycle();
        }
        finish(result.containsKey("error") ? 0 : -1, result);
    }
}
