package ru.mangapad.legacy;

import java.io.FileInputStream;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONObject;

/** Run the actual transport on Gingerbread without attaching a debugger. */
public final class DeviceNetworkCheck {
    private static long started;
    private static void begin(String phase) {
        started = System.nanoTime();
        System.out.println("START " + phase);
        System.out.flush();
    }
    private static void done(String phase, int count) {
        System.out.println("PASS " + phase + " "
            + TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) + " ms; count=" + count);
        System.out.flush();
    }
    public static void main(String[] args) throws Exception {
        begin("initialize");
        LegacyHttp http = new LegacyHttp(new FileInputStream(args[0]));
        done("initialize", 1);
        try {
            if (args.length > 1 && "--roots".equals(args[1])) return;
            MangaApi api = new MangaApi(http);
            JSONObject selected = null;
            for (String query : new String[] { "chainsaw", "naruto", "chainsaw" }) {
                RequestDeadline deadline = new RequestDeadline(30000);
                RequestDeadline.enter(deadline);
                begin("search");
                try {
                    JSONArray titles = api.search(query);
                    if (titles.length() == 0) throw new AssertionError("No search results");
                    if (selected == null) {
                        selected = titles.getJSONObject(0);
                        for (int i = 0; i < titles.length(); i++) {
                            JSONObject item = titles.getJSONObject(i);
                            if ("chainsaw-man".equals(item.optString("slug"))) selected = item;
                        }
                    }
                    done("search", titles.length());
                } finally { RequestDeadline.leave(); deadline.cancel(); }
            }
            String slug = selected.getString("slug_url");
            begin("title");
            api.title(slug); done("title", 1);
            begin("chapters");
            JSONArray chapters = api.chapters(slug); done("chapters", chapters.length());
            begin("chapter");
            JSONArray pages = api.chapter(slug, chapters.getJSONObject(0)); done("chapter", pages.length());
            begin("image");
            byte[] image = api.page(pages.getJSONObject(0));
            if (image.length < 1000) throw new AssertionError("Empty image");
            done("image", image.length);
        } finally { http.close(); }
    }
}
