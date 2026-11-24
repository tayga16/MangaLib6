package ru.mangapad.legacy;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.graphics.drawable.*;
import android.os.*;
import android.view.*;
import android.view.animation.*;
import android.view.inputmethod.*;
import android.widget.*;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

public final class MainActivity extends Activity {
    private static final int BACKGROUND = 0xffffefe0, SURFACE = 0xfffffaf1;
    private static final int ACCENT = 0xffe66e1f, INK = 0xff4d2612, MUTED = 0xff855027;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler handler = new Handler();
    private static final int REQUEST_TIMEOUT = 30000;
    private Future<?> pendingRequest, pendingCover;
    private RequestDeadline requestDeadline, coverDeadline;
    private Runnable requestTimeout;
    private ReadingStore store;
    private ChapterDownloads downloads;
    private PageSources pageSources;
    private JSONObject offlineChapter, downloading;
    private RequestDeadline downloadDeadline;
    private int downloadToken;
    private boolean downloadRunning, downloadsReader;
    private LinearLayout downloadBar;
    private TextView downloadStatus;
    private MangaApi api;
    private volatile LegacyHttp transport;
    private LinearLayout root, content, body, toolbar, readerControls;
    private TextView heading, status, readerInfo;
    private EditText query;
    private Button back, previous, next, retry, cancel, fullscreen, downloadChapter;
    private AlertDialog failureDialog;
    private PageView pageView;
    private Bitmap coverBitmap;
    private JSONObject manga, currentChapter, resumeWanted;
    private JSONArray results = new JSONArray(), chapters = new JSONArray(), pages = new JSONArray();
    private int screen, chapterIndex = -1, pageIndex;
    private volatile int generation;
    private boolean history = true, busy;
    private volatile boolean dead;
    private String lastQuery = "";
    private Runnable retryAction;
    private String initError;
    private boolean readerFullscreen, retryAvailable, lowMemory, fullscreenHintShown, foreground;
    private volatile int bufferGeneration;
    private Future<?> pendingPrefetch;
    private RequestDeadline prefetchDeadline;
    private final Set<Integer> prefetchErrors = new HashSet<Integer>();
    private final PageBuffer<Bitmap> pageBuffer = new PageBuffer<Bitmap>(
        Math.min(8L * 1024 * 1024, Runtime.getRuntime().maxMemory() / 4),
        new PageBuffer.Disposal<Bitmap>() { public void release(Bitmap image) { image.recycle(); } });

    private interface Work { Object run() throws Exception; }
    private interface Done { void run(Object value); }

    public void onCreate(Bundle state) {
        super.onCreate(state);
        store = new ReadingStore(getSharedPreferences("reader", MODE_PRIVATE));
        downloads = new ChapterDownloads(new File(getFilesDir(), "chapters"));
        pageSources = new PageSources(new File(getCacheDir(), "reader-originals"), 64L * 1024 * 1024);
        root = vertical(); root.setBackgroundColor(BACKGROUND);
        LinearLayout bar = horizontal(); toolbar = bar;
        bar.setPadding(dp(6), dp(5), dp(6), dp(5)); bar.setBackgroundColor(ACCENT);
        back = button("‹ Назад", new Runnable() { public void run() { goBack(); } });
        bar.addView(back, new LinearLayout.LayoutParams(dp(83), dp(44)));
        heading = text("OldLib", 20, Color.WHITE); heading.setTypeface(null, Typeface.BOLD);
        heading.setSingleLine(); heading.setEllipsize(android.text.TextUtils.TruncateAt.END);
        bar.addView(heading, new LinearLayout.LayoutParams(0, dp(44), 1));
        fullscreen = button("Полный экран", new Runnable() { public void run() { setReaderFullscreen(true); } });
        fullscreen.setTextSize(12); fullscreen.setVisibility(View.GONE);
        bar.addView(fullscreen, new LinearLayout.LayoutParams(dp(100), dp(44)));
        root.addView(bar);
        status = text("", 12, MUTED); status.setPadding(dp(10), dp(5), dp(10), dp(5));
        status.setMaxLines(4);
        root.addView(status, new LinearLayout.LayoutParams(-1, -2));
        downloadBar = horizontal(); downloadBar.setPadding(dp(8), dp(4), dp(8), dp(4));
        downloadStatus = text("", 12, MUTED);
        downloadBar.addView(downloadStatus, new LinearLayout.LayoutParams(0, dp(42), 1));
        downloadBar.addView(button("Отмена", new Runnable() { public void run() { stopDownload("Скачивание приостановлено"); } }),
            new LinearLayout.LayoutParams(dp(80), dp(42)));
        root.addView(downloadBar); downloadBar.setVisibility(View.GONE);
        retry = button("Повторить загрузку", new Runnable() { public void run() {
            if (retryAction != null && !busy) retryAction.run();
        } });
        root.addView(retry, new LinearLayout.LayoutParams(-1, dp(44))); retry.setVisibility(View.GONE);
        cancel = button("Отменить загрузку", new Runnable() { public void run() {
            if (!busy) return;
            invalidateRequest(); setStatus("Загрузка отменена");
            showRetry(true); pageControls();
        } });
        root.addView(cancel, new LinearLayout.LayoutParams(-1, dp(44))); cancel.setVisibility(View.GONE);
        content = vertical(); root.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
        FrameLayout frame = new FrameLayout(this);
        frame.addView(root, new FrameLayout.LayoutParams(-1, -1));
        readerInfo = text("", 11, Color.WHITE); readerInfo.setMaxLines(3);
        readerInfo.setPadding(dp(8), dp(3), dp(8), dp(3)); readerInfo.setBackgroundColor(0xc0191310);
        readerInfo.setVisibility(View.GONE);
        readerInfo.setOnClickListener(new View.OnClickListener() { public void onClick(View view) { setReaderFullscreen(false); } });
        frame.addView(readerInfo, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
        setContentView(frame);
        // Transport and CA parsing initialize off the UI thread, before queued requests.
        worker.execute(new Runnable() { public void run() {
            long started = System.nanoTime();
            try {
                transport = new LegacyHttp(getAssets().open("cacert.pem"));
                if (dead) { transport.close(); return; }
                api = new MangaApi(transport);
                android.util.Log.i("MangaLib", "HTTPS ready in "
                    + TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) + " ms");
            }
            catch (Exception error) {
                initError = error.getMessage(); android.util.Log.e("MangaLib", "HTTPS initialization failed", error);
            }
            catch (LinkageError error) {
                initError = "Ошибка совместимости Android: " + error.toString();
                android.util.Log.e("MangaLib", "HTTPS initialization failed", error);
            }
        } });
        showHome(0);
        if (state != null) {
            lastQuery = state.getString("query"); if (lastQuery == null) lastQuery = ""; query.setText(lastQuery);
            try {
                String titleState = state.getString("title");
                JSONObject savedTitle = new JSONObject(titleState == null ? "{}" : titleState);
                if (savedTitle.optString("slug_url").length() > 0) {
                    if (state.getBoolean("reading")) {
                        resumeWanted = store.progress(savedTitle.optString("slug_url"));
                        JSONObject local = resumeWanted == null ? null : downloads.ready(savedTitle.optString("slug_url"), resumeWanted);
                        if (local != null) { openDownloaded(local, resumeWanted.optInt("page")); return; }
                    }
                    openManga(savedTitle);
                }
            } catch (JSONException ignored) { }
        }
    }

    private int dp(float value) { return (int)(value * getResources().getDisplayMetrics().density + .5f); }
    private LinearLayout vertical() { LinearLayout view = new LinearLayout(this); view.setOrientation(1); return view; }
    private LinearLayout horizontal() { LinearLayout view = new LinearLayout(this); view.setOrientation(0); return view; }
    private TextView text(String value, int size, int color) {
        TextView view = new TextView(this); view.setText(value); view.setTextSize(size);
        view.setTextColor(color); view.setGravity(Gravity.CENTER_VERTICAL); return view;
    }
    private GradientDrawable background(int color) {
        GradientDrawable drawable = new GradientDrawable(); drawable.setColor(color); drawable.setCornerRadius(dp(7));
        drawable.setStroke(dp(1), color == ACCENT ? 0xffb95b1c : 0xffdeb18c); return drawable;
    }
    private Button button(String title, final Runnable action) {
        Button view = new Button(this); view.setText(title); view.setTextSize(14); view.setTextColor(Color.WHITE);
        view.setBackgroundDrawable(background(ACCENT)); view.setPadding(dp(6), 0, dp(6), 0);
        view.setOnClickListener(new View.OnClickListener() { public void onClick(View view) { action.run(); } });
        return view;
    }
    private void enter(int nextScreen, String title, int direction) {
        invalidateRequest(); retryAction = null; showRetry(false);
        if (pageView != null) { pageView.release(); pageView = null; }
        pageBuffer.clear(); prefetchErrors.clear(); readerControls = null;
        pageSources.pin(null);
        downloadChapter = null;
        if (coverBitmap != null) { coverBitmap.recycle(); coverBitmap = null; }
        screen = nextScreen; content.removeAllViews(); heading.setText(title);
        setReaderFullscreen(false);
        back.setVisibility(screen == 0 ? View.GONE : View.VISIBLE);
        setStatus(""); animate(content, direction);
    }
    private void setStatus(String message) {
        status.setText(message); readerInfo.setText(message);
    }
    private void showRetry(boolean available) { retryAvailable = available; updateReaderChrome(); }
    private void setReaderFullscreen(boolean enabled) {
        readerFullscreen = enabled && screen == 3;
        if (readerFullscreen) getWindow().addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
        else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
        updateReaderChrome();
    }
    private void updateReaderChrome() {
        toolbar.setVisibility(readerFullscreen ? View.GONE : View.VISIBLE);
        status.setVisibility(readerFullscreen ? View.GONE : View.VISIBLE);
        fullscreen.setVisibility(screen == 3 && !readerFullscreen ? View.VISIBLE : View.GONE);
        readerInfo.setVisibility(readerFullscreen ? View.VISIBLE : View.GONE);
        if (readerControls != null) readerControls.setVisibility(readerFullscreen ? View.GONE : View.VISIBLE);
        retry.setVisibility(retryAvailable && !readerFullscreen ? View.VISIBLE : View.GONE);
        cancel.setVisibility(busy && !readerFullscreen ? View.VISIBLE : View.GONE);
        if (downloadBar != null) downloadBar.setVisibility(downloadRunning && !readerFullscreen ? View.VISIBLE : View.GONE);
        updateDownloadButton();
    }
    private void updateDownloadButton() {
        if (downloadChapter == null || screen != 3) return;
        boolean saved = offlineChapter != null || downloads.complete(downloads.get(ChapterDownloads.key(manga.optString("slug_url"), currentChapter)));
        downloadChapter.setVisibility(readerFullscreen ? View.GONE : View.VISIBLE);
        downloadChapter.setText(downloadRunning ? "Отмена скачивания" : saved ? "Глава скачана" : "Скачать главу");
        downloadChapter.setEnabled(!busy && (downloadRunning || !saved));
    }
    private void animate(View view, int direction) {
        if (direction == 0) return;
        TranslateAnimation animation = new TranslateAnimation(Animation.RELATIVE_TO_SELF,
            direction > 0 ? 1 : -1, Animation.RELATIVE_TO_SELF, 0,
            Animation.RELATIVE_TO_SELF, 0, Animation.RELATIVE_TO_SELF, 0);
        animation.setDuration(280); animation.setInterpolator(new DecelerateInterpolator()); view.startAnimation(animation);
    }
    private ScrollView scrolling(LinearLayout parent) {
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true);
        body = vertical(); body.setPadding(dp(10), dp(8), dp(10), dp(12)); scroll.addView(body);
        parent.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1)); return scroll;
    }
    private LinearLayout row(LinearLayout parent, String title, String detail, final Runnable action) {
        LinearLayout card = vertical(); card.setPadding(dp(12), dp(9), dp(12), dp(9));
        card.setBackgroundDrawable(background(SURFACE));
        TextView name = text(title, 16, INK); name.setTypeface(null, Typeface.BOLD); card.addView(name);
        if (detail.length() > 0) { TextView sub = text(detail, 12, MUTED); sub.setPadding(0, dp(4), 0, 0); card.addView(sub); }
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2); params.bottomMargin = dp(7);
        parent.addView(card, params);
        if (action != null) {
            card.setMinimumHeight(dp(56)); card.setOnClickListener(new View.OnClickListener() {
                public void onClick(View view) { action.run(); }
            }); card.setFocusable(true);
        }
        return card;
    }
    private void resumeCard(LinearLayout parent, final JSONObject saved) {
        if (saved == null) return;
        LinearLayout card = row(parent, "Продолжить читать", MangaApi.name(saved) + "\n"
            + MangaApi.chapterLabel(saved) + " · Страница " + (saved.optInt("page") + 1)
            + " / " + saved.optInt("page_count") + "\nОсталось в главе: "
            + Math.max(0, saved.optInt("page_count") - saved.optInt("page") - 1), new Runnable() {
                public void run() { if (!busy) {
                    JSONObject local = downloads.ready(saved.optString("slug_url"), saved);
                    if (local != null) openDownloaded(local, saved.optInt("page"));
                    else { resumeWanted = saved; openManga(saved); }
                } }
            });
        card.setBackgroundDrawable(background(0xff35251d));
        ((TextView)card.getChildAt(0)).setTextColor(Color.WHITE);
        ((TextView)card.getChildAt(1)).setTextColor(0xffffc393);
        ProgressBar progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(saved.optInt("page_count")); progress.setProgress(saved.optInt("page") + 1);
        card.addView(progress, new LinearLayout.LayoutParams(-1, dp(10)));
    }
    private void showHome(int direction) {
        enter(0, "OldLib", direction);
        LinearLayout search = horizontal(); search.setPadding(dp(8), dp(6), dp(8), dp(4));
        query = new EditText(this); query.setSingleLine(); query.setTextSize(16); query.setTextColor(INK);
        query.setHint("Название манги"); query.setText(lastQuery); query.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
        query.setInputType(android.text.InputType.TYPE_CLASS_TEXT);
        query.setBackgroundDrawable(background(SURFACE)); query.setPadding(dp(8), 0, dp(8), 0);
        search.addView(query, new LinearLayout.LayoutParams(0, dp(44), 1));
        Button find = button("Поиск", new Runnable() { public void run() { search(query.getText().toString()); } });
        LinearLayout.LayoutParams fp = new LinearLayout.LayoutParams(dp(72), dp(44)); fp.leftMargin = dp(5); search.addView(find, fp);
        content.addView(search);
        query.setOnEditorActionListener(new TextView.OnEditorActionListener() {
            public boolean onEditorAction(TextView view, int action, KeyEvent event) {
                if (action == EditorInfo.IME_ACTION_SEARCH || event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER
                        && event.getAction() == KeyEvent.ACTION_UP) { search(query.getText().toString()); return true; }
                return false;
            }
        });
        LinearLayout tools = horizontal(); tools.setPadding(dp(8), 0, dp(8), dp(5));
        tools.addView(button("История", new Runnable() { public void run() {
            history = true; invalidateRequest(); showRetry(false); homeRows();
        } }), new LinearLayout.LayoutParams(0, dp(40), 1));
        Button clear = button("Очистить", new Runnable() { public void run() {
            store.clearHistory(); history = true; invalidateRequest(); showRetry(false); homeRows();
        } });
        LinearLayout.LayoutParams cp = new LinearLayout.LayoutParams(0, dp(40), 1); cp.leftMargin = dp(6); tools.addView(clear, cp);
        content.addView(tools); scrolling(content); homeRows();
        root.setFocusableInTouchMode(true); root.requestFocus();
    }
    private void homeRows() {
        body.removeAllViews(); resumeCard(body, store.lastProgress());
        row(body, "Загрузки", "Скачанные главы · Читать без интернета", new Runnable() { public void run() { showDownloads(); } });
        if (history) {
            row(body, "История поиска", "Нажми запрос, чтобы повторить. Удерживай, чтобы удалить.", null);
            for (final String saved : store.history()) {
                LinearLayout card = row(body, saved, "", new Runnable() { public void run() { query.setText(saved); search(saved); } });
                card.setOnLongClickListener(new View.OnLongClickListener() { public boolean onLongClick(View view) {
                    store.deleteSearch(saved); homeRows(); return true;
                } });
            }
            if (store.history().isEmpty()) row(body, "Пока пусто", "Введи название манги выше.", null);
            row(body, "Проверить соединение", "Проверка доступа к MangaLib через интернет", new Runnable() {
                public void run() { checkConnection(); }
            });
            setStatus("OldLib 0.1.0 · Тестовая версия · Android 2.3+");
        } else {
            for (int i = 0; i < results.length(); i++) {
                final JSONObject item = results.optJSONObject(i); if (item == null) continue;
                JSONObject saved = store.progress(item.optString("slug_url"));
                row(body, MangaApi.name(item), saved == null ? item.optString("name") : MangaApi.chapterLabel(saved)
                    + " · Страница " + (saved.optInt("page") + 1), new Runnable() { public void run() { openManga(item); } });
            }
            if (results.length() == 0) row(body, "Ничего не найдено", "Попробуй другое название.", null);
            setStatus("Найдено: " + results.length());
        }
    }
    private void checkConnection() {
        if (busy) return;
        request("Проверка соединения с MangaLib…", new Work() { public Object run() throws Exception {
            return Integer.valueOf(api.checkConnection());
        } }, new Done() { public void run(Object value) {
            setStatus("Соединение работает · Серверов страниц: " + value);
        } }, new Runnable() { public void run() { checkConnection(); } });
    }
    private void search(final String value) {
        final String term = value.trim();
        if (term.length() == 0) { invalidateRequest(); history = true; showRetry(false); homeRows(); return; }
        lastQuery = term; query.setText(term); store.addSearch(term);
        ((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(query.getWindowToken(), 0);
        invalidateRequest();
        request("Поиск…", new Work() { public Object run() throws Exception { return api.search(term); } },
            new Done() { public void run(Object value) { results = (JSONArray)value; history = false; homeRows(); } },
            new Runnable() { public void run() { search(term); } });
    }
    private void openManga(final JSONObject item) {
        downloadsReader = false; offlineChapter = null;
        manga = item; chapters = new JSONArray(); chapterIndex = -1;
        enter(1, MangaApi.name(manga), 1); scrolling(content); titleRows();
        final String slug = item.optString("slug_url");
        request("Загрузка информации…", new Work() { public Object run() throws Exception { return api.title(slug); } },
            new Done() { public void run(Object value) { manga = (JSONObject)value; titleRows();
                if (resumeWanted != null) openChapters(); else loadCover(); } },
            new Runnable() { public void run() { openManga(item); } });
    }
    private void titleRows() {
        body.removeAllViews(); row(body, MangaApi.name(manga), manga.optString("name"), null);
        resumeCard(body, store.progress(manga.optString("slug_url")));
        Button read = button("Открыть главы", new Runnable() { public void run() { if (!busy) openChapters(); } });
        body.addView(read, new LinearLayout.LayoutParams(-1, dp(46)));
        String summary = manga.optString("summary", "");
        summary = android.text.Html.fromHtml(summary).toString().trim();
        row(body, "О манге", "Год: " + manga.optString("releaseDate", "—") + "\nГлав: "
            + manga.optString("chap_count", "—") + (summary.length() > 0 ? "\n\n" + summary : ""), null);
    }
    private void loadCover() {
        final String address = MangaApi.cover(manga); if (!address.startsWith("https://")) return;
        final int token = generation;
        final ImageView cover = new ImageView(this); cover.setScaleType(ImageView.ScaleType.FIT_CENTER);
        body.addView(cover, 1, new LinearLayout.LayoutParams(-1, dp(200)));
        final RequestDeadline deadline = new RequestDeadline(12000);
        coverDeadline = deadline;
        pendingCover = worker.submit(new Runnable() { public void run() {
            if (dead || token != generation) return;
            RequestDeadline.enter(deadline);
            Bitmap loaded = null;
            try { loaded = decode(api.image(address), 300, 450); } catch (Exception ignored) { }
            catch (OutOfMemoryError ignored) { }
            finally { RequestDeadline.leave(); deadline.cancel(); }
            final Bitmap image = loaded;
            handler.post(new Runnable() { public void run() {
                if (!dead && generation == token && screen == 1) { coverBitmap = image; cover.setImageBitmap(image); }
                else if (image != null) image.recycle();
            } });
        } });
    }
    private void openChapters() {
        enter(2, "Главы", 1); scrolling(content); resumeCard(body, store.progress(manga.optString("slug_url")));
        final String slug = manga.optString("slug_url");
        request("Загрузка глав…", new Work() { public Object run() throws Exception { return api.chapters(slug); } },
            new Done() { public void run(Object value) {
                chapters = (JSONArray)value; chapterRows();
                if (resumeWanted != null) {
                    JSONObject saved = resumeWanted; resumeWanted = null;
                    int found = ReadingStore.findChapter(chapters, saved);
                    if (found >= 0) openChapter(found, saved.optInt("page"), 1);
                    else setStatus("Сохранённая глава не найдена. Выбери другую.");
                }
            } }, new Runnable() { public void run() { openChapters(); } });
    }
    private void chapterRows() {
        body.removeAllViews(); JSONObject saved = store.progress(manga.optString("slug_url")); resumeCard(body, saved);
        final int savedIndex = ReadingStore.findChapter(chapters, saved);
        for (int i = 0; i < chapters.length(); i++) {
            final int index = i; final JSONObject chapter = chapters.optJSONObject(i); if (chapter == null) continue;
            final JSONObject local = downloads.get(ChapterDownloads.key(manga.optString("slug_url"), chapter));
            LinearLayout card = row(body, MangaApi.chapterLabel(chapter), chapter.optString("name")
                + "\n" + ChapterMetadata.publicationLabel(chapter)
                + (downloads.complete(local) ? "\nСкачана · Доступна без интернета" : "")
                + (i == savedIndex ? "\nПродолжить со страницы " + (saved.optInt("page") + 1) : ""),
                new Runnable() { public void run() {
                    JSONObject progress = store.progress(manga.optString("slug_url"));
                    openChapter(index, ReadingStore.findChapter(chapters, progress) == index ? progress.optInt("page") : 0, 1);
                } });
            Button save = button(downloads.complete(local) ? "Глава скачана" : local == null ? "Скачать главу" : "Продолжить скачивание",
                new Runnable() { public void run() {
                    startDownload(manga, chapter);
                } });
            save.setEnabled(!downloads.complete(local));
            card.addView(save, new LinearLayout.LayoutParams(-1, dp(40)));
        }
        setStatus("Глав: " + chapters.length());
    }
    private void showDownloads() {
        offlineChapter = null; downloadsReader = false;
        enter(4, "Загрузки", 1); scrolling(content);
        List<JSONObject> items = downloads.list();
        if (items.isEmpty()) row(body, "Нет скачанных глав", "Открой список глав и нажми «Скачать главу».", null);
        for (final JSONObject item : items) {
            JSONObject title = item.optJSONObject("manga"), chapter = item.optJSONObject("chapter");
            final boolean ready = downloads.complete(item);
            LinearLayout card = row(body, MangaApi.name(title) + " · " + MangaApi.chapterLabel(chapter),
                (ready ? "Без интернета" : "Не завершена") + " · Страниц: " + downloads.count(item) + " / "
                    + item.optJSONArray("pages").length() + "\n" + ChapterMetadata.publicationLabel(chapter), ready ? new Runnable() { public void run() {
                        JSONObject saved = store.progress(item.optJSONObject("manga").optString("slug_url"));
                        openDownloaded(item, saved != null && ReadingStore.findChapter(new JSONArray().put(item.optJSONObject("chapter")), saved) == 0
                            ? saved.optInt("page") : 0);
                    } } : null);
            if (!ready) card.addView(button("Продолжить скачивание", new Runnable() { public void run() {
                startDownload(item.optJSONObject("manga"), item.optJSONObject("chapter"));
            } }), new LinearLayout.LayoutParams(-1, dp(40)));
            card.addView(button("Удалить", new Runnable() { public void run() {
                new AlertDialog.Builder(MainActivity.this).setTitle("Удалить скачанную главу?")
                    .setMessage("Сохранённое место чтения останется.")
                    .setNegativeButton("Отмена", null).setPositiveButton("Удалить", new DialogInterface.OnClickListener() {
                        public void onClick(DialogInterface dialog, int which) {
                            stopDownload("");
                            // Queue deletion after any cancelled writer has stopped.
                            worker.execute(new Runnable() { public void run() {
                                String failure = null;
                                try { downloads.delete(item.optString("id")); } catch (Exception error) { failure = error.getMessage(); }
                                final String problem = failure;
                                handler.post(new Runnable() { public void run() {
                                    if (dead) return;
                                    if (screen == 4) showDownloads();
                                    if (problem != null) setStatus(problem);
                                } });
                            } });
                        }
                    }).show();
            } }), new LinearLayout.LayoutParams(-1, dp(40)));
        }
        setStatus("Глав в загрузках: " + items.size() + " · Для удаления нажми «Удалить»");
    }
    private void openDownloaded(JSONObject item, int resumePage) {
        if (busy || !downloads.complete(item)) return;
        stopDownload("");
        manga = item.optJSONObject("manga"); downloadsReader = true; offlineChapter = item;
        // Retain chapter order for offline continuation without fetching the catalog.
        List<JSONObject> local = downloads.list();
        Collections.sort(local, new Comparator<JSONObject>() { public int compare(JSONObject a, JSONObject b) {
            JSONObject ac = a.optJSONObject("chapter"), bc = b.optJSONObject("chapter");
            try {
                int volume = new java.math.BigDecimal(ac.optString("volume")).compareTo(new java.math.BigDecimal(bc.optString("volume")));
                return volume == 0 ? new java.math.BigDecimal(ac.optString("number")).compareTo(new java.math.BigDecimal(bc.optString("number"))) : volume;
            } catch (Exception error) { return ac.optString("number").compareTo(bc.optString("number")); }
        } });
        chapters = new JSONArray();
        for (JSONObject entry : local) if (downloads.complete(entry) && manga.optString("slug_url").equals(entry.optJSONObject("manga").optString("slug_url")))
            chapters.put(entry.optJSONObject("chapter"));
        int index = ReadingStore.findChapter(chapters, item.optJSONObject("chapter"));
        buildReader(index, resumePage, 1, item.optJSONObject("chapter"), item.optJSONArray("pages"));
    }
    private void startDownload(final JSONObject title, final JSONObject chapter) {
        if (busy || downloadRunning || dead) return;
        cancelPrefetch(); downloading = null; downloadRunning = true;
        final JSONArray knownPages = screen == 3 && chapter == currentChapter ? pages : null;
        final int token = ++downloadToken;
        downloadStatus.setText("Получаем главу…"); updateReaderChrome();
        final RequestDeadline deadline = new RequestDeadline(30000); downloadDeadline = deadline;
        watchDownload(token, deadline);
        worker.execute(new Runnable() { public void run() {
            JSONObject item = null; String failure = null;
            RequestDeadline.enter(deadline);
            try {
                deadline.remainingMillis();
                if (api == null) throw new IOException(initError == null ? "Сеть не готова" : initError);
                JSONObject existing = downloads.get(ChapterDownloads.key(title.optString("slug_url"), chapter));
                JSONArray chapterPages = knownPages != null ? knownPages : existing == null ? api.chapter(title.optString("slug_url"), chapter) : existing.getJSONArray("pages");
                deadline.remainingMillis();
                item = downloads.prepare(title, chapter, chapterPages);
            } catch (Exception error) { failure = error.getMessage(); }
            catch (OutOfMemoryError error) { failure = "Недостаточно памяти для скачивания"; }
            finally { RequestDeadline.leave(); deadline.cancel(); }
            final JSONObject value = item; final String problem = failure;
            handler.post(new Runnable() { public void run() {
                if (dead || token != downloadToken) return;
                downloadDeadline = null;
                if (value == null) { stopDownload(problem == null ? "Не удалось скачать главу" : problem); return; }
                downloading = value; downloadNext(token);
            } });
        } });
    }
    private void downloadNext(final int token) {
        if (dead || !downloadRunning || token != downloadToken) return;
        final JSONObject item = downloading;
        int wanted = -1;
        for (int i = 0; i < item.optJSONArray("pages").length(); i++) if (!downloads.hasPage(item, i)) { wanted = i; break; }
        final int index = wanted;
        downloadStatus.setText("Скачивание: " + downloads.count(item) + " / " + item.optJSONArray("pages").length());
        final RequestDeadline deadline = new RequestDeadline(30000); downloadDeadline = deadline;
        watchDownload(token, deadline);
        worker.execute(new Runnable() { public void run() {
            String failure = null;
            RequestDeadline.enter(deadline);
            try {
                deadline.remainingMillis();
                if (index < 0) downloads.finish(item);
                else {
                    byte[] bytes = api.page(item.getJSONArray("pages").getJSONObject(index));
                    BitmapFactory.Options bounds = new BitmapFactory.Options(); bounds.inJustDecodeBounds = true;
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
                    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw new IOException("Страница повреждена или не поддерживается");
                    deadline.remainingMillis(); downloads.putPage(item, index, bytes);
                }
            } catch (Exception error) { failure = error.getMessage(); }
            catch (OutOfMemoryError error) { failure = "Недостаточно памяти для скачивания"; }
            finally { RequestDeadline.leave(); deadline.cancel(); }
            final String problem = failure;
            handler.post(new Runnable() { public void run() {
                if (dead || token != downloadToken) return;
                downloadDeadline = null;
                if (problem != null) stopDownload(problem + " · Можно продолжить в «Загрузках»");
                else if (index < 0) {
                    stopDownload("Глава скачана · Доступна без интернета");
                    if (screen == 4) showDownloads(); else if (screen == 2) chapterRows();
                } else handler.postDelayed(new Runnable() { public void run() { downloadNext(token); } }, 100);
            } });
        } });
    }
    private void watchDownload(final int token, final RequestDeadline deadline) {
        handler.postDelayed(new Runnable() { public void run() {
            if (!dead && downloadRunning && token == downloadToken && downloadDeadline == deadline)
                stopDownload("Сервер не ответил за 30 секунд · Продолжить можно в «Загрузках»");
        } }, 30000);
    }
    private void stopDownload(String message) {
        if (!downloadRunning) return;
        downloadRunning = false; downloadToken++;
        if (downloadDeadline != null) { downloadDeadline.cancel(); downloadDeadline = null; }
        updateReaderChrome();
        if (!dead && message.length() > 0) { setStatus(message); Toast.makeText(this, message, Toast.LENGTH_LONG).show(); }
    }
    private void openChapter(final int index, final int resumePage, final int direction) {
        if (busy || index < 0 || index >= chapters.length()) return;
        final JSONObject chapter = chapters.optJSONObject(index);
        if (chapter == null) return;
        final String slug = manga.optString("slug_url");
        final JSONObject local = downloads.ready(slug, chapter);
        if (local != null) { stopDownload(""); offlineChapter = local; buildReader(index, resumePage, direction, chapter, local.optJSONArray("pages")); return; }
        offlineChapter = null;
        request("Загрузка главы…", new Work() { public Object run() throws Exception {
            return api.chapter(slug, chapter);
        } }, new Done() { public void run(Object value) {
            buildReader(index, resumePage, direction, chapter, (JSONArray)value);
        } }, new Runnable() { public void run() { openChapter(index, resumePage, direction); } });
    }
    private void buildReader(int index, int resumePage, int direction, JSONObject chapter, JSONArray chapterPages) {
            pages = chapterPages; currentChapter = chapter; chapterIndex = index;
            boolean stayFullscreen = screen != 3 || readerFullscreen;
            enter(3, MangaApi.chapterLabel(chapter), direction);
            lowMemory = false;
            pageView = new PageView(MainActivity.this, new PageView.Listener() {
                public void turn(int direction) { turnPage(direction); }
                public void tap() { setReaderFullscreen(!readerFullscreen); }
            });
            content.addView(pageView, new LinearLayout.LayoutParams(-1, 0, 1));
            downloadChapter = button("Скачать главу", new Runnable() { public void run() {
                if (downloadRunning) stopDownload("Скачивание приостановлено"); else startDownload(manga, currentChapter);
            } });
            content.addView(downloadChapter, new LinearLayout.LayoutParams(-1, dp(40)));
            LinearLayout controls = horizontal(); readerControls = controls;
            controls.setPadding(dp(6), dp(5), dp(6), dp(5));
            previous = button("‹ Страница", new Runnable() { public void run() { turnPage(-1); } });
            next = button("Страница ›", new Runnable() { public void run() { turnPage(1); } });
            controls.addView(previous, new LinearLayout.LayoutParams(0, dp(44), 1));
            LinearLayout.LayoutParams np = new LinearLayout.LayoutParams(0, dp(44), 1); np.leftMargin = dp(6); controls.addView(next, np);
            content.addView(controls);
            setReaderFullscreen(stayFullscreen);
            pageIndex = Math.max(0, Math.min(resumePage, pages.length() - 1)); loadPage(pageIndex, 0);
    }
    private void turnPage(int direction) {
        if (busy || screen != 3 || !pageView.hasPage()) return;
        int target = pageIndex + direction;
        if (target >= 0 && target < pages.length()) loadPage(target, direction);
        else if (direction > 0 && chapterIndex + 1 < chapters.length()) openChapter(chapterIndex + 1, 0, 1);
    }
    private void loadPage(final int target, final int direction) {
        final JSONObject page = pages.optJSONObject(target);
        if (page == null) { setStatus("Нет данных страницы"); return; }
        cancelPrefetch();
        Bitmap cached = pageBuffer.get(target);
        if (cached != null) {
            dismissFailure(); retryAction = null; showRetry(false);
            displayPage(target, cached, direction); return;
        }
        final JSONObject local = offlineChapter;
        request("Загрузка страницы " + (target + 1) + " / " + pages.length() + "…", new Work() {
            public Object run() throws Exception {
                Bitmap image = pageBitmap(page, local, target);
                if (image == null) throw new IOException("Формат картинки не поддерживается Android 2.3");
                return image;
            }
        }, new Done() { public void run(Object value) {
            displayPage(target, (Bitmap)value, direction);
        } }, new Runnable() { public void run() { loadPage(target, direction); } });
    }
    private void displayPage(int target, Bitmap image, int direction) {
        pageIndex = target;
        File source = pageSources.file(pages.optJSONObject(target).optString("url"));
        pageSources.pin(source); pageView.setPage(image, source);
        pageBuffer.show(target, pages.length(), image, bitmapBytes(image));
        pageBuffer.rememberSource(target, source);
        if (lowMemory) pageBuffer.keepCurrent();
        for (int failed : new ArrayList<Integer>(prefetchErrors)) {
            if (failed <= target || failed >= target + pageBuffer.forwardLimit()) prefetchErrors.remove(Integer.valueOf(failed));
        }
        prefetchErrors.remove(Integer.valueOf(target));
        animate(pageView, direction);
        store.save(manga, currentChapter, pageIndex, pages.length()); pageControls(); updatePageStatus();
        if (!fullscreenHintShown) {
            fullscreenHintShown = true;
            Toast.makeText(this, "Коснись страницы, чтобы скрыть или показать панели", Toast.LENGTH_LONG).show();
        }
        prefetchPages();
    }
    private static long bitmapBytes(Bitmap image) { return (long)image.getRowBytes() * image.getHeight(); }
    private void updatePageStatus() {
        if (screen != 3 || busy || retryAvailable) return;
        setStatus("Страница " + (pageIndex + 1) + " / " + pages.length()
            + " · Осталось: " + Math.max(0, pages.length() - pageIndex - 1)
            + (offlineChapter != null ? " · Без интернета" : "")
            + "\nБуфер: " + pageBuffer.forwardCount() + " / " + pageBuffer.forwardLimit()
            + " · Назад: " + pageBuffer.historyCount());
    }
    private void cancelPrefetch() {
        bufferGeneration++;
        if (prefetchDeadline != null) { prefetchDeadline.cancel(); prefetchDeadline = null; }
        if (pendingPrefetch != null) { pendingPrefetch.cancel(true); pendingPrefetch = null; }
    }
    private void prefetchPages() {
        if (dead || !foreground || screen != 3 || busy || retryAvailable || pendingPrefetch != null
                || !pageView.hasPage()) return;
        int wanted = pageBuffer.nextPrefetch(prefetchErrors);
        if (wanted < 0) return;
        final int target = wanted, token = bufferGeneration;
        final JSONObject page = pages.optJSONObject(target);
        if (page == null) { prefetchErrors.add(Integer.valueOf(target)); prefetchPages(); return; }
        final JSONObject local = offlineChapter;
        final boolean decodeAhead = !lowMemory && pageBuffer.hasRoom(pageBuffer.estimatedPageBytes());
        final File source = pageSources.file(page.optString("url"));
        final RequestDeadline deadline = new RequestDeadline(12000);
        prefetchDeadline = deadline;
        pendingPrefetch = worker.submit(new Runnable() { public void run() {
            if (dead || token != bufferGeneration) return;
            Bitmap loaded = null; boolean memoryFailure = false, succeeded = false;
            RequestDeadline.enter(deadline);
            try {
                deadline.remainingMillis();
                byte[] bytes = local == null ? pageSources.read(page.optString("url")) : null;
                if (bytes == null) bytes = pageBytes(page, local, target);
                // Network prefetch continues even when sharp bitmaps fill RAM.
                succeeded = true;
                if (decodeAhead) loaded = decodePage(bytes);
                deadline.remainingMillis();
            }
            catch (OutOfMemoryError error) { memoryFailure = true; }
            catch (Exception ignored) { }
            catch (LinkageError ignored) { }
            finally { RequestDeadline.leave(); deadline.cancel(); }
            final Bitmap image = loaded; final boolean outOfMemory = memoryFailure, complete = succeeded;
            handler.post(new Runnable() { public void run() {
                if (dead || token != bufferGeneration || screen != 3) { if (image != null) image.recycle(); return; }
                pendingPrefetch = null; prefetchDeadline = null;
                if (complete) pageBuffer.rememberSource(target, source);
                if (outOfMemory) {
                    lowMemory = true; pageBuffer.keepCurrent();
                    if (pageView != null) pageView.releaseDetail();
                    if (image != null) image.recycle();
                } else if (!complete) {
                    if (image != null) image.recycle();
                    prefetchErrors.add(Integer.valueOf(target));
                } else if (image != null) {
                    // A full decoded buffer still has the original on disk.
                    pageBuffer.offer(target, image, bitmapBytes(image));
                }
                // Cache-write failure must not spin on the same uncached page.
                if (complete && pageBuffer.nextPrefetch(prefetchErrors) == target)
                    prefetchErrors.add(Integer.valueOf(target));
                updatePageStatus(); prefetchPages();
            } });
        } });
    }
    private void pageControls() {
        if (screen != 3 || next == null) return;
        updateDownloadButton();
        previous.setEnabled(!busy && pageView.hasPage() && pageIndex > 0);
        boolean last = pageIndex + 1 >= pages.length();
        next.setText(last ? chapterIndex + 1 < chapters.length() ? "След. глава ›" : "Конец манги" : "Страница ›");
        next.setEnabled(!busy && pageView.hasPage() && (!last || chapterIndex + 1 < chapters.length()));
    }
    private void request(String message, final Work work, final Done done, Runnable again) {
        if (busy || dead) return;
        stopDownload("Скачивание приостановлено. Продолжи в «Загрузках».");
        cancelPrefetch();
        dismissFailure();
        busy = true; retryAction = again; showRetry(false); updateReaderChrome();
        final String loadingMessage = message;
        final long startedAt = SystemClock.elapsedRealtime();
        setStatus(message + " · 0 / 30 с"); pageControls();
        final int token = generation;
        final RequestDeadline deadline = new RequestDeadline(REQUEST_TIMEOUT);
        requestDeadline = deadline;
        final Runnable timeout = new Runnable() { public void run() {
            if (dead || token != generation || !busy) return;
            long elapsed = SystemClock.elapsedRealtime() - startedAt;
            if (elapsed < REQUEST_TIMEOUT) {
                setStatus(loadingMessage + " · " + elapsed / 1000 + " / 30 с");
                handler.postDelayed(this, Math.min(500, REQUEST_TIMEOUT - elapsed));
                return;
            }
            invalidateRequest();
            android.util.Log.w("MangaLib", "Request reached UI deadline: " + loadingMessage);
            showFailure("Загрузка остановлена: нет ответа за 30 секунд. Проверь интернет и повтори.");
        } };
        requestTimeout = timeout;
        handler.postDelayed(timeout, 500);
        pendingRequest = worker.submit(new Runnable() { public void run() {
            if (dead || token != generation) return;
            RequestDeadline.enter(deadline);
            Object result = null; String failure = null;
            try {
                deadline.remainingMillis();
                if (api == null && offlineChapter == null) throw new IOException(initError == null ? "Сеть не инициализирована" : initError);
                result = work.run();
                deadline.remainingMillis();
            } catch (OutOfMemoryError error) { failure = "Недостаточно памяти для страницы"; }
            catch (LinkageError error) {
                android.util.Log.e("MangaLib", "Android runtime compatibility", error);
                failure = "Ошибка совместимости Android: " + error.toString();
            }
            catch (UnknownHostException error) {
                android.util.Log.w("MangaLib", "DNS failed", error);
                failure = "Не удалось найти сервер. Проверь Wi-Fi или мобильный интернет.";
            }
            catch (SocketTimeoutException error) {
                android.util.Log.w("MangaLib", "Request timed out", error);
                failure = "Сервер не ответил вовремя. Проверь интернет и повтори.";
            }
            catch (ConnectException error) {
                android.util.Log.w("MangaLib", "Connection failed", error);
                failure = "Нет соединения с сервером. Проверь интернет и повтори.";
            }
            catch (Exception error) {
                android.util.Log.w("MangaLib", "Request failed", error);
                failure = error.getMessage() == null ? error.toString() : error.getMessage();
            }
            finally { RequestDeadline.leave(); deadline.cancel(); }
            final Object value = result; final String problem = failure;
            handler.post(new Runnable() { public void run() {
                if (dead || token != generation) { if (value instanceof Bitmap) ((Bitmap)value).recycle(); return; }
                handler.removeCallbacks(timeout); requestTimeout = null; pendingRequest = null; requestDeadline = null;
                busy = false; cancel.setVisibility(View.GONE); pageControls();
                if (problem != null) {
                    if (value instanceof Bitmap) ((Bitmap)value).recycle();
                    if ("Недостаточно памяти для страницы".equals(problem)) {
                        lowMemory = true; pageBuffer.keepCurrent();
                    }
                    showFailure(problem);
                }
                else { retryAction = null; done.run(value); }
            } });
        } });
    }
    private void invalidateRequest() {
        cancelPrefetch();
        generation++; busy = false; showRetry(false);
        if (cancel != null) cancel.setVisibility(View.GONE);
        dismissFailure();
        if (requestTimeout != null) { handler.removeCallbacks(requestTimeout); requestTimeout = null; }
        if (requestDeadline != null) { requestDeadline.cancel(); requestDeadline = null; }
        if (coverDeadline != null) { coverDeadline.cancel(); coverDeadline = null; }
        if (pendingRequest != null) { pendingRequest.cancel(true); pendingRequest = null; }
        if (pendingCover != null) { pendingCover.cancel(true); pendingCover = null; }
    }
    private void dismissFailure() {
        if (failureDialog != null) { failureDialog.dismiss(); failureDialog = null; }
    }
    private void showFailure(String problem) {
        if (dead || isFinishing()) return;
        setReaderFullscreen(false);
        setStatus(problem); showRetry(true); cancel.setVisibility(View.GONE); pageControls();
        if (screen == 0) {
            body.removeAllViews();
            row(body, "Не удалось загрузить", problem + "\nНажми «Повторить загрузку» или введи другое название.", null);
        }
        dismissFailure();
        failureDialog = new AlertDialog.Builder(this).setTitle("Не удалось загрузить")
            .setMessage(problem).setPositiveButton("Понятно", null).show();
    }
    protected void onResume() {
        super.onResume();
        foreground = true;
        if (requestTimeout != null) { handler.removeCallbacks(requestTimeout); requestTimeout.run(); }
        prefetchPages();
    }
    protected void onPause() {
        foreground = false; cancelPrefetch();
        stopDownload("Скачивание приостановлено. Продолжи в «Загрузках».");
        LegacyHttp http = transport; if (http != null) http.closeIdle();
        super.onPause();
    }
    public void onLowMemory() {
        super.onLowMemory(); cancelPrefetch(); lowMemory = true;
        if (pageView != null) pageView.releaseDetail();
        pageBuffer.keepCurrent(); updatePageStatus();
    }
    private Bitmap pageBitmap(JSONObject page, JSONObject local, int index) throws Exception {
        if (local == null) {
            byte[] cached = pageSources.read(page.optString("url"));
            if (cached != null) {
                try { return decodePage(cached); }
                catch (IOException broken) {
                    android.util.Log.w("MangaLib", "Cached page cannot be decoded; fetching original", broken);
                }
            }
        }
        return decodePage(pageBytes(page, local, index));
    }
    private byte[] pageBytes(JSONObject page, JSONObject local, int index) throws Exception {
        byte[] bytes = local == null ? api.page(page) : downloads.page(local, index);
        RequestDeadline deadline = RequestDeadline.current();
        if (deadline != null) deadline.remainingMillis();
        try { pageSources.put(page.optString("url"), bytes); }
        catch (IOException error) { android.util.Log.w("MangaLib", "Cannot cache page original", error); }
        return bytes;
    }
    private static Bitmap decodePage(byte[] bytes) throws IOException {
        BitmapFactory.Options bounds = new BitmapFactory.Options(); bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw new IOException("Неподдерживаемая картинка");
        BitmapFactory.Options options = new BitmapFactory.Options();
        // Decode the sharper JPEG before showing it, within the same byte budget.
        long pixels = PageResolution.pagePixels(Runtime.getRuntime().maxMemory(), "image/jpeg".equals(bounds.outMimeType));
        options.inSampleSize = PageResolution.sampleSize(bounds.outWidth, bounds.outHeight, pixels);
        options.inPreferredConfig = Bitmap.Config.RGB_565;
        for (;;) {
            try {
                Bitmap decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
                if (decoded == null) throw new IOException("Не удалось прочитать картинку");
                return decoded;
            }
            catch (OutOfMemoryError error) {
                if (options.inSampleSize >= Math.max(bounds.outWidth, bounds.outHeight)) throw error;
                options.inSampleSize *= 2;
            }
        }
    }
    private static Bitmap decode(byte[] bytes, int maxWidth, int maxHeight) throws IOException {
        BitmapFactory.Options bounds = new BitmapFactory.Options(); bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw new IOException("Неподдерживаемая картинка");
        BitmapFactory.Options options = new BitmapFactory.Options(); options.inSampleSize = 1;
        while (bounds.outWidth / options.inSampleSize > maxWidth
                || bounds.outHeight / options.inSampleSize > maxHeight
                || (long)(bounds.outWidth / options.inSampleSize) * (bounds.outHeight / options.inSampleSize) > 1500000) {
            options.inSampleSize *= 2;
        }
        options.inPreferredConfig = Bitmap.Config.RGB_565;
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
    }
    private void goBack() {
        resumeWanted = null;
        if (screen == 4 || screen == 3 && downloadsReader || screen == 2 && downloadsReader) {
            if (screen == 4) { downloadsReader = false; offlineChapter = null; showHome(-1); }
            else showDownloads();
            return;
        }
        offlineChapter = null;
        if (screen == 0) { finish(); return; }
        if (screen == 1) showHome(-1);
        else if (screen == 2) { enter(1, MangaApi.name(manga), -1); scrolling(content); titleRows(); loadCover(); }
        else { enter(2, "Главы", -1); scrolling(content); chapterRows(); }
    }
    public void onBackPressed() {
        if (readerFullscreen) setReaderFullscreen(false); else goBack();
    }
    protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        state.putString("query", query == null ? lastQuery : query.getText().toString());
        if (screen != 0 && manga != null) state.putString("title", manga.toString());
        state.putBoolean("reading", screen == 3);
    }
    protected void onDestroy() {
        stopDownload("");
        dead = true; invalidateRequest(); worker.shutdownNow();
        LegacyHttp http = transport; if (http != null) http.close();
        if (pageView != null) pageView.release();
        pageBuffer.clear();
        if (coverBitmap != null) coverBitmap.recycle();
        super.onDestroy();
    }
}
