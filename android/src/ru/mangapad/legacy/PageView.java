package ru.mangapad.legacy;

import android.content.Context;
import android.graphics.*;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.*;
import java.io.File;
import java.util.concurrent.*;

/** One decoded page, zoom and gestures without AndroidX or API 11 features. */
final class PageView extends View {
    interface Listener { void turn(int direction); void tap(); }
    interface RegionDecoder {
        Detail decode(RectF visible, long pixels, int previewWidth, int previewHeight,
            float displayWidth, float displayHeight) throws java.io.IOException;
        void close();
    }
    static final class Detail {
        final Bitmap bitmap;
        final RectF region;
        final int sourceWidth, sourceHeight, sample;
        Detail(Bitmap bitmap, RectF region, int sourceWidth, int sourceHeight, int sample) {
            this.bitmap = bitmap; this.region = region;
            this.sourceWidth = sourceWidth; this.sourceHeight = sourceHeight; this.sample = sample;
        }
        void recycle() { if (!bitmap.isRecycled()) bitmap.recycle(); }
    }
    // One native decode at a time; a second queue slot allows retiring a source.
    private static final ThreadPoolExecutor decoder = new ThreadPoolExecutor(1, 1, 20,
        TimeUnit.SECONDS, new ArrayBlockingQueue<Runnable>(2));
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Listener listener;
    private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
    private final RectF drawBounds = new RectF();
    private final RectF drawRegion = new RectF();
    private final GestureDetector gestures;
    private final ScaleGestureDetector pinch;
    private Bitmap bitmap;
    private File source;
    private RegionSource regionSource;
    private Detail detail;
    private RectF requested;
    private int generation;
    private FutureTask<Void> detailTask;
    private boolean preparingDetail;
    private final Runnable decodeLater = new Runnable() { public void run() { loadDetail(); } };
    private float zoom = 1, x, y;
    private boolean pinching;
    private static final PageDecoder.Factory<RegionDecoder> regionFactory = new PageDecoder.Factory<RegionDecoder>() {
        public RegionDecoder open(File file) throws java.io.IOException { return PageRegion.open(file); }
        public void close(RegionDecoder reader) { reader.close(); }
    };

    private final class RegionSource {
        final PageDecoder<RegionDecoder> reader;
        RegionSource(File file) { reader = new PageDecoder<RegionDecoder>(file, regionFactory); }
        Detail decode(final RectF region, final long pixels, final int width, final int height,
                final float displayWidth, final float displayHeight) throws java.io.IOException {
            return reader.decode(new PageDecoder.Operation<RegionDecoder, Detail>() {
                public Detail decode(RegionDecoder decoder) throws java.io.IOException {
                    return decoder.decode(region, pixels, width, height, displayWidth, displayHeight);
                }
            });
        }
        void retire() {
            reader.retire();
            final Runnable cleanup = new Runnable() { public void run() { reader.close(); } };
            Runnable enqueue = new Runnable() { public void run() {
                try { decoder.execute(cleanup); }
                catch (RejectedExecutionException full) { handler.postDelayed(this, 50); }
            } };
            enqueue.run();
        }
    }

    PageView(Context context, Listener listener) {
        super(context); this.listener = listener;
        setBackgroundColor(Color.rgb(23, 19, 17));
        gestures = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
            public boolean onDown(MotionEvent event) { return true; }
            public boolean onSingleTapConfirmed(MotionEvent event) {
                if (!pinching) performClick();
                return true;
            }
            public boolean onDoubleTap(MotionEvent event) {
                if (!pinching) scaleAt(zoom > 1.01f ? 1 : 2.5f, event.getX(), event.getY());
                return true;
            }
            public boolean onScroll(MotionEvent first, MotionEvent second, float dx, float dy) {
                if (zoom > 1.01f && !pinching) { x -= dx; y -= dy; clamp(); invalidate(); requestDetail(); }
                return true;
            }
            public boolean onFling(MotionEvent first, MotionEvent second, float vx, float vy) {
                if (bitmap != null && !pinching && zoom <= 1.01f
                        && Math.abs(second.getX() - first.getX()) > 55 * getResources().getDisplayMetrics().density
                        && Math.abs(vx) > Math.abs(vy)) {
                    PageView.this.listener.turn(vx < 0 ? 1 : -1);
                }
                return true;
            }
        });
        pinch = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            public boolean onScaleBegin(ScaleGestureDetector detector) { pinching = true; return bitmap != null; }
            public boolean onScale(ScaleGestureDetector detector) {
                scaleAt(Math.max(1, Math.min(4, zoom * detector.getScaleFactor())),
                    detector.getFocusX(), detector.getFocusY());
                return true;
            }
        });
        setContentDescription("Страница манги. Касание показывает панели, свайп перелистывает, двойное нажатие увеличивает.");
    }
    void setPage(Bitmap next) { setPage(next, null); }
    void setPage(Bitmap next, File original) {
        // PageBuffer owns and recycles bitmaps after they leave the view.
        clearDetail(); retireSource(); source = original;
        if (original != null && Build.VERSION.SDK_INT >= 10) regionSource = new RegionSource(original);
        bitmap = next; zoom = 1; x = y = 0; invalidate(); requestDetail();
    }
    boolean hasPage() { return bitmap != null; }
    void release() { clearAnimation(); setPage(null); }
    private float fit() {
        return bitmap == null ? 1 : Math.min((float)getWidth() / bitmap.getWidth(), (float)getHeight() / bitmap.getHeight());
    }
    private void scaleAt(float next, float focusX, float focusY) {
        float ratio = next / zoom;
        x = focusX - getWidth() / 2f - (focusX - getWidth() / 2f - x) * ratio;
        y = focusY - getHeight() / 2f - (focusY - getHeight() / 2f - y) * ratio;
        zoom = next; clamp(); invalidate(); requestDetail();
    }
    private void clamp() {
        if (bitmap == null) return;
        float maxX = Math.max(0, (bitmap.getWidth() * fit() * zoom - getWidth()) / 2f);
        float maxY = Math.max(0, (bitmap.getHeight() * fit() * zoom - getHeight()) / 2f);
        x = Math.max(-maxX, Math.min(maxX, x)); y = Math.max(-maxY, Math.min(maxY, y));
    }
    protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) { clamp(); requestDetail(); }
    private RectF pageBounds() {
        float width = bitmap.getWidth() * fit() * zoom, height = bitmap.getHeight() * fit() * zoom;
        drawBounds.set((getWidth() - width) / 2 + x, (getHeight() - height) / 2 + y,
            (getWidth() + width) / 2 + x, (getHeight() + height) / 2 + y);
        return drawBounds;
    }
    private RectF visibleRegion(float margin) {
        RectF bounds = pageBounds();
        // A small margin keeps the sharp overlay visible during a short pan.
        float extraX = getWidth() * margin, extraY = getHeight() * margin;
        return new RectF(Math.max(0, (-extraX - bounds.left) / bounds.width()),
            Math.max(0, (-extraY - bounds.top) / bounds.height()),
            Math.min(1, (getWidth() + extraX - bounds.left) / bounds.width()),
            Math.min(1, (getHeight() + extraY - bounds.top) / bounds.height()));
    }
    private void cancelDetailTask() {
        handler.removeCallbacks(decodeLater);
        if (detailTask != null) {
            detailTask.cancel(true); decoder.remove(detailTask); detailTask = null;
        }
    }
    void clearDetail() {
        generation++; cancelDetailTask(); requested = null; preparingDetail = false;
        if (detail != null) { detail.recycle(); detail = null; }
    }
    void releaseDetail() { clearDetail(); retireSource(); }
    private void retireSource() {
        if (regionSource != null) { regionSource.retire(); regionSource = null; }
    }
    private boolean covers(Detail image, RectF visible) {
        if (image == null || !image.region.contains(visible)) return false;
        RectF bounds = pageBounds();
        RectF region = visibleRegion(.15f);
        int width = Math.min(image.sourceWidth, (int)Math.ceil(region.right * image.sourceWidth))
            - Math.max(0, (int)Math.floor(region.left * image.sourceWidth));
        int height = Math.min(image.sourceHeight, (int)Math.ceil(region.bottom * image.sourceHeight))
            - Math.max(0, (int)Math.floor(region.top * image.sourceHeight));
        // Also accept the best available source/memory-limited sample. Otherwise
        // every movement would decode the same pixels again on low-heap devices.
        return image.sample <= PageResolution.detailSample(image.sourceWidth, image.sourceHeight,
            width, height, bounds.width(), bounds.height(), detailPixels());
    }
    private long detailPixels() {
        return Math.max(1, Math.min(4L * 1024 * 1024, Runtime.getRuntime().maxMemory() / 8) / 4);
    }
    private boolean previewIsSharp() {
        RectF bounds = pageBounds();
        return bitmap.getWidth() >= bounds.width() && bitmap.getHeight() >= bounds.height();
    }
    private void requestDetail() {
        if (bitmap == null || source == null || Build.VERSION.SDK_INT < 10) {
            clearDetail(); return;
        }
        if (getWidth() <= 0 || getHeight() <= 0) return;
        if (regionSource == null) regionSource = new RegionSource(source);
        if (zoom <= 1.01f) {
            // Retain the sharp crop across zoom-out. Prepare the centre at the
            // maximum gesture zoom while the user reads the fitted page.
            if (detail != null) {
                generation++; cancelDetailTask(); requested = null; preparingDetail = false; return;
            }
            float width = bitmap.getWidth() * fit() * 4, height = bitmap.getHeight() * fit() * 4;
            if (bitmap.getWidth() >= width && bitmap.getHeight() >= height) return;
            RectF region = new RectF(Math.max(0, .5f - getWidth() * .65f / width),
                Math.max(0, .5f - getHeight() * .65f / height),
                Math.min(1, .5f + getWidth() * .65f / width),
                Math.min(1, .5f + getHeight() * .65f / height));
            if (region.equals(requested)) return;
            generation++; cancelDetailTask(); requested = region; preparingDetail = true;
            handler.postDelayed(decodeLater, 150); return;
        }
        RectF visible = visibleRegion(0);
        if (previewIsSharp() || covers(detail, visible)) {
            // A running preparation remains useful after a modest zoom.
            if (preparingDetail && requested != null) return;
            generation++; cancelDetailTask(); requested = null; preparingDetail = false; return;
        }
        RectF region = visibleRegion(.15f);
        if (region.equals(requested)) return;
        generation++; cancelDetailTask(); requested = region; preparingDetail = false;
        handler.postDelayed(decodeLater, pinching ? 100 : 40);
    }
    private void loadDetail() {
        if (requested == null || source == null) return;
        final RectF region = new RectF(requested);
        final RegionSource original = regionSource;
        if (original == null || original.reader.retired) return;
        final int token = generation;
        final boolean prepared = preparingDetail;
        final int previewWidth = bitmap.getWidth(), previewHeight = bitmap.getHeight();
        final RectF bounds = pageBounds();
        final float displayWidth = prepared ? bitmap.getWidth() * fit() * 4 : bounds.width();
        final float displayHeight = prepared ? bitmap.getHeight() * fit() * 4 : bounds.height();
        final long pixels = detailPixels();
        detailTask = new FutureTask<Void>(new Runnable() { public void run() {
            Detail decoded = null;
            try {
                if (!Thread.currentThread().isInterrupted())
                    decoded = original.decode(region, pixels, previewWidth, previewHeight, displayWidth, displayHeight);
            } catch (Exception error) {
                // Unsupported regions (e.g. GIF) or an evicted source keep the preview.
            } catch (OutOfMemoryError error) { }
            final Detail result = decoded;
            boolean posted = handler.post(new Runnable() { public void run() {
                if (bitmap == null || original != regionSource || original.reader.retired) {
                    if (result != null) result.recycle(); return;
                }
                if (token == generation) { detailTask = null; requested = null; preparingDetail = false; }
                if (result != null) {
                    // A short pan need not discard a completed sharp region.
                    RectF visible = visibleRegion(0);
                    // A modest zoom can show the sharp preview while keeping
                    // the pending centre ready for a subsequent stronger zoom.
                    boolean retainPreparation = prepared && detail == null
                        && (zoom <= 1.01f || previewIsSharp());
                    if (!retainPreparation && (zoom <= 1.01f || !result.region.contains(visible)
                            || covers(detail, visible) || detail != null
                            && detail.region.contains(visible) && detail.sample <= result.sample)) {
                        result.recycle(); return;
                    }
                    if (detail != null) detail.recycle();
                    detail = result; invalidate();
                }
            } });
            if (!posted && result != null) result.recycle();
        } }, null);
        try { decoder.execute(detailTask); }
        catch (RejectedExecutionException full) {
            detailTask = null; handler.postDelayed(decodeLater, 40);
        }
    }
    protected void onAttachedToWindow() { super.onAttachedToWindow(); requestDetail(); }
    protected void onDetachedFromWindow() { clearDetail(); retireSource(); super.onDetachedFromWindow(); }
    protected void onDraw(Canvas canvas) {
        if (bitmap == null) return;
        RectF bounds = pageBounds();
        // If the detail covers the viewport, avoid painting the preview under it
        // on Gingerbread's software canvas.
        if (zoom <= 1.01f || detail == null || !detail.region.contains(visibleRegion(0)))
            canvas.drawBitmap(bitmap, null, bounds, paint);
        if (detail != null && zoom > 1.01f) {
            RectF region = detail.region;
            drawRegion.set(bounds.left + region.left * bounds.width(),
                bounds.top + region.top * bounds.height(), bounds.left + region.right * bounds.width(),
                bounds.top + region.bottom * bounds.height());
            canvas.drawBitmap(detail.bitmap, null, drawRegion, paint);
        }
    }
    public boolean onTouchEvent(MotionEvent event) {
        pinch.onTouchEvent(event); gestures.onTouchEvent(event);
        if (event.getAction() == MotionEvent.ACTION_UP || event.getAction() == MotionEvent.ACTION_CANCEL) {
            if (pinching) {
                pinching = false;
                // Start the final detail promptly when the fingers leave the screen.
                if (requested != null && detailTask == null) {
                    handler.removeCallbacks(decodeLater); handler.postDelayed(decodeLater, 40);
                }
                else requestDetail();
            }
        }
        return true;
    }
    public boolean performClick() { super.performClick(); listener.tap(); return true; }
}
