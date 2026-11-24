package ru.mangapad.legacy;

import android.content.SharedPreferences;
import java.util.*;
import org.json.*;

final class ReadingStore {
    private final SharedPreferences prefs;
    ReadingStore(SharedPreferences prefs) { this.prefs = prefs; }

    List<String> history() {
        List<String> result = new ArrayList<String>();
        try {
            JSONArray saved = new JSONArray(prefs.getString("history", "[]"));
            for (int i = 0; i < saved.length() && result.size() < 20; i++) {
                Object value = saved.opt(i);
                if (!(value instanceof String)) continue;
                String query = ((String)value).trim();
                boolean duplicate = false;
                for (String old : result) if (old.equalsIgnoreCase(query)) duplicate = true;
                if (query.length() > 0 && !duplicate) result.add(query);
            }
        } catch (JSONException ignored) { }
        return result;
    }
    void addSearch(String query) {
        query = query.trim();
        if (query.length() == 0) return;
        List<String> list = history();
        for (Iterator<String> it = list.iterator(); it.hasNext();) if (it.next().equalsIgnoreCase(query)) it.remove();
        list.add(0, query);
        while (list.size() > 20) list.remove(list.size() - 1);
        saveHistory(list);
    }
    void deleteSearch(String query) {
        List<String> list = history(); list.remove(query); saveHistory(list);
    }
    void clearHistory() { saveHistory(new ArrayList<String>()); }
    private void saveHistory(List<String> list) {
        prefs.edit().putString("history", new JSONArray(list).toString()).commit();
    }
    JSONObject progress(String slug) {
        if (slug.length() == 0) return null;
        try {
            JSONObject value = new JSONObject(prefs.getString("progress:" + slug, "{}"));
            return value.optInt("page_count") > 0 && value.optInt("page", -1) >= 0
                && value.optString("number").length() > 0 ? value : null;
        } catch (JSONException ignored) { return null; }
    }
    JSONObject lastProgress() { return progress(prefs.getString("last_slug", "")); }
    void save(JSONObject title, JSONObject chapter, int page, int count) {
        String slug = title.optString("slug_url");
        if (slug.length() == 0 || count <= 0 || page < 0 || page >= count) return;
        JSONObject value = new JSONObject();
        try {
            value.put("slug_url", slug); value.put("rus_name", MangaApi.name(title));
            value.put("volume", chapter.optString("volume")); value.put("number", chapter.optString("number"));
            value.put("page", page); value.put("page_count", count);
            JSONObject cover = title.optJSONObject("cover");
            if (cover != null) value.put("cover", cover);
            prefs.edit().putString("progress:" + slug, value.toString()).putString("last_slug", slug).commit();
        } catch (JSONException ignored) { }
    }
    static int findChapter(JSONArray chapters, JSONObject saved) {
        if (saved == null) return -1;
        for (int i = 0; i < chapters.length(); i++) {
            JSONObject chapter = chapters.optJSONObject(i);
            if (chapter != null && chapter.optString("volume").equals(saved.optString("volume"))
                    && chapter.optString("number").equals(saved.optString("number"))) return i;
        }
        return -1;
    }
}
