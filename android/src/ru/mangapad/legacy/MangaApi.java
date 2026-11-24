package ru.mangapad.legacy;

import java.io.*;
import java.net.URLEncoder;
import java.util.*;
import org.json.*;

public class MangaApi {
    private final LegacyHttp http;
    private final String[] endpoints;
    private int activeEndpoint;
    private JSONArray servers;
    private int activeImageServer = -1;
    public MangaApi(LegacyHttp http) {
        this(http, new String[] { "https://api.cdnlibs.org/api", "https://api.lib.social/api" });
    }
    MangaApi(LegacyHttp http, String[] endpoints) {
        this.http = http;
        this.endpoints = endpoints.clone();
    }

    private static boolean unavailable(IOException error) {
        return LegacyHttp.retryable(error) || error instanceof java.net.UnknownHostException;
    }

    private Object fetch(String path) throws Exception {
        IOException first = null;
        int start = activeEndpoint;
        for (int attempt = 0; attempt < endpoints.length; attempt++) {
            int selected = (start + attempt) % endpoints.length;
            byte[] response;
            try { response = http.getOnce(endpoints[selected] + path); }
            catch (IOException error) {
                RequestDeadline deadline = RequestDeadline.current();
                if (deadline != null) deadline.remainingMillis();
                // A certificate error, access restriction or rate limit needs
                // attention, rather than repeated requests to another host.
                if (!unavailable(error)) throw error;
                if (first == null) first = error;
                if (attempt + 1 == endpoints.length) {
                    throw new IOException("Не удалось загрузить данные MangaLib.\n" + first.getMessage()
                        + (first == error ? "" : "\nРезервный API: " + error.getMessage()), error);
                }
                continue;
            }
            try {
                Object data = new JSONObject(new String(response, "UTF-8")).get("data");
                activeEndpoint = selected;
                return data;
            } catch (JSONException error) {
                throw new IOException("Сервер вернул неожиданный ответ вместо данных MangaLib", error);
            }
        }
        throw new IOException("Нет адресов API MangaLib");
    }
    public int checkConnection() throws Exception {
        JSONArray available = ((JSONObject)fetch("/constants?fields%5B%5D=imageServers")).getJSONArray("imageServers");
        int count = 0;
        for (int i = 0; i < available.length(); i++) {
            JSONObject server = available.optJSONObject(i);
            if (server == null || !server.optString("url").startsWith("https://")) continue;
            JSONArray sites = server.optJSONArray("site_ids");
            if (sites != null) for (int j = 0; j < sites.length(); j++) if (sites.optInt(j) == 1) { count++; break; }
        }
        if (count == 0) throw new IOException("API отвечает, но серверы страниц MangaLib не найдены");
        servers = available;
        return count;
    }
    static String escape(String value) throws UnsupportedEncodingException {
        return URLEncoder.encode(value, "UTF-8").replace("+", "%20");
    }
    public JSONArray search(String query) throws Exception {
        return (JSONArray)fetch("/manga?site_id%5B%5D=1&q=" + escape(query) + "&per_page=20");
    }
    public JSONObject title(String slug) throws Exception {
        return (JSONObject)fetch("/manga/" + escape(slug)
            + "?fields%5B%5D=authors&fields%5B%5D=format&fields%5B%5D=chap_count&fields%5B%5D=releaseDate");
    }
    public JSONArray chapters(String slug) throws Exception {
        return (JSONArray)fetch("/manga/" + escape(slug) + "/chapters");
    }
    public JSONArray chapter(String slug, JSONObject chapter) throws Exception {
        JSONArray branches = chapter.optJSONArray("branches");
        int count = branches == null || branches.length() == 0 ? 1 : branches.length();
        for (int i = 0; i < count; i++) {
            String path = "/manga/" + escape(slug) + "/chapter?volume="
                + escape(chapter.optString("volume")) + "&number=" + escape(chapter.optString("number"));
            JSONObject branch = branches == null ? null : branches.optJSONObject(i);
            if (branch != null && !branch.isNull("branch_id")) path += "&branch_id=" + escape(branch.optString("branch_id"));
            JSONObject result = (JSONObject)fetch(path);
            JSONObject restriction = result.optJSONObject("restricted_view");
            if (restriction != null && !restriction.optBoolean("is_open")) continue;
            JSONArray pages = result.optJSONArray("pages");
            if (pages != null && pages.length() > 0) return pages;
        }
        throw new IOException("Нет открытого перевода этой главы");
    }
    public byte[] image(String address) throws Exception { return http.get(address); }
    public byte[] page(JSONObject page) throws Exception {
        if (servers == null) {
            servers = ((JSONObject)fetch("/constants?fields%5B%5D=imageServers")).getJSONArray("imageServers");
        }
        String path = page.optString("url");
        while (path.startsWith("/")) path = path.substring(1);
        if (path.length() == 0) throw new IOException("Нет адреса страницы");
        Exception last = new IOException("Нет серверов изображений");
        List<Integer> candidates = new ArrayList<Integer>();
        JSONObject remembered = servers.optJSONObject(activeImageServer);
        if (remembered != null && !"compress".equals(remembered.optString("id"))) candidates.add(activeImageServer);
        // Compressed copies can erase small text. Prefer a supported original,
        // and do not let a temporary compressed fallback become permanent.
        for (String kind : new String[] { "download", "main", "secondary", "compress" }) {
            for (int i = 0; i < servers.length(); i++) {
                JSONObject server = servers.optJSONObject(i);
                if (server != null && kind.equals(server.optString("id")) && !candidates.contains(i)) candidates.add(i);
            }
        }
        for (int i : candidates) {
            JSONObject server = servers.optJSONObject(i);
            if (server == null) continue;
            JSONArray sites = server.optJSONArray("site_ids");
            boolean allowed = false;
            if (sites != null) for (int j = 0; j < sites.length(); j++) if (sites.optInt(j) == 1) allowed = true;
            String base = server.optString("url");
            if (!allowed || !base.startsWith("https://")) continue;
            try {
                // Switch image hosts instead of retrying a failing host twice.
                byte[] bytes = http.getOnce(base.replaceAll("/+$", "") + "/" + path);
                if (!supportedImage(bytes)) throw new IOException("Сервер вернул формат картинки, недоступный Android 2.3");
                activeImageServer = i;
                return bytes;
            }
            catch (Exception error) {
                RequestDeadline deadline = RequestDeadline.current();
                if (deadline != null) deadline.remainingMillis();
                last = error;
            }
        }
        throw last;
    }
    static boolean supportedImage(byte[] bytes) {
        if (bytes.length < 8) return false;
        return (bytes[0] == (byte)0xff && bytes[1] == (byte)0xd8)
            || (bytes[0] == (byte)0x89 && bytes[1] == 'P' && bytes[2] == 'N' && bytes[3] == 'G'
                && bytes[4] == 13 && bytes[5] == 10 && bytes[6] == 26 && bytes[7] == 10)
            || (bytes[0] == 'G' && bytes[1] == 'I' && bytes[2] == 'F' && bytes[3] == '8');
    }
    static String name(JSONObject title) {
        String name = title.optString("rus_name", "");
        return name.length() == 0 ? title.optString("name", "Без названия") : name;
    }
    static String cover(JSONObject title) {
        JSONObject cover = title.optJSONObject("cover");
        if (cover == null) return "";
        return cover.optString("md", cover.optString("default", ""));
    }
    static String chapterLabel(JSONObject chapter) {
        return "Том " + chapter.optString("volume") + " · Глава " + chapter.optString("number");
    }
}
