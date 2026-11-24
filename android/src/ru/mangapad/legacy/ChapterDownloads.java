package ru.mangapad.legacy;

import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import org.json.*;

/** Persistent chapter files. A chapter is ready only after every page is committed. */
final class ChapterDownloads {
    private final File root;
    ChapterDownloads(File root) { this.root = root; }

    static String key(String slug, JSONObject chapter) {
        try {
            JSONArray identity = new JSONArray(); identity.put(slug);
            identity.put(chapter.optString("volume")); identity.put(chapter.optString("number"));
            return hash(identity.toString().getBytes("UTF-8"));
        } catch (Exception error) { throw new IllegalStateException(error); }
    }
    private static String hash(byte[] data) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(data);
        StringBuilder value = new StringBuilder();
        for (byte part : digest) value.append(String.format(Locale.US, "%02x", part & 255));
        return value.toString();
    }
    private File directory(String id) throws IOException {
        if (!id.matches("[a-f0-9]{64}")) throw new IOException("Неверный адрес загрузки");
        File folder = new File(root, id);
        if (!folder.getCanonicalFile().getParentFile().equals(root.getCanonicalFile()))
            throw new IOException("Неверный каталог загрузки");
        return folder;
    }
    private static byte[] bytes(File file, int limit) throws IOException {
        long size = file.length();
        if (size <= 0 || size > limit) throw new IOException("Файл загрузки повреждён");
        FileInputStream input = new FileInputStream(file);
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream((int)size);
            byte[] buffer = new byte[16384]; int count;
            while ((count = input.read(buffer)) != -1) {
                if (out.size() + count > limit) throw new IOException("Файл слишком большой");
                out.write(buffer, 0, count);
            }
            return out.toByteArray();
        } finally { input.close(); }
    }
    private static void atomic(File file, byte[] data) throws IOException {
        File temporary = new File(file.getParentFile(), file.getName() + ".tmp");
        File backup = new File(file.getParentFile(), file.getName() + ".bak");
        FileOutputStream output = new FileOutputStream(temporary);
        try { output.write(data); output.getFD().sync(); } finally { output.close(); }
        if (backup.exists() && !backup.delete()) throw new IOException("Не удалось обновить загрузку");
        if (file.exists() && !file.renameTo(backup)) throw new IOException("Не удалось обновить загрузку");
        if (!temporary.renameTo(file)) {
            backup.renameTo(file); throw new IOException("Не удалось сохранить загрузку: проверь свободное место");
        }
        backup.delete();
    }
    synchronized JSONObject get(String id) {
        try {
            File folder = directory(id), file = new File(folder, "chapter.json");
            if (!file.exists()) file = new File(folder, "chapter.json.bak");
            JSONObject item = new JSONObject(new String(bytes(file, 2 * 1024 * 1024), "UTF-8"));
            if (!id.equals(item.optString("id")) || !id.equals(key(item.getJSONObject("manga").optString("slug_url"),
                    item.getJSONObject("chapter")))) return null;
            JSONArray pages = item.getJSONArray("pages"), sizes = item.getJSONArray("sizes"), hashes = item.getJSONArray("hashes");
            if (pages.length() == 0 || sizes.length() != pages.length() || hashes.length() != pages.length()) return null;
            for (int i = 0; i < pages.length(); i++) {
                if (pages.getJSONObject(i).getString("url").length() == 0 || sizes.getLong(i) < 0 ||
                    sizes.getLong(i) > 20 * 1024 * 1024) return null;
                hashes.getString(i);
            }
            return item;
        } catch (Exception error) { return null; }
    }
    synchronized List<JSONObject> list() {
        List<JSONObject> items = new ArrayList<JSONObject>();
        File[] folders = root.listFiles();
        if (folders != null) for (File folder : folders) {
            JSONObject item = get(folder.getName()); if (item != null) items.add(item);
        }
        Collections.sort(items, new Comparator<JSONObject>() { public int compare(JSONObject a, JSONObject b) {
            return Long.valueOf(b.optLong("saved_at")).compareTo(Long.valueOf(a.optLong("saved_at")));
        } });
        return items;
    }
    synchronized JSONObject ready(String slug, JSONObject chapter) {
        JSONObject item = get(key(slug, chapter));
        return complete(item) ? item : null;
    }
    synchronized boolean complete(JSONObject item) {
        return item != null && item.optBoolean("complete") && count(item) == item.optJSONArray("pages").length();
    }
    synchronized int count(JSONObject item) {
        if (item == null) return 0;
        int count = 0;
        JSONArray sizes = item.optJSONArray("sizes");
        if (sizes != null) for (int i = 0; i < sizes.length(); i++) if (hasPage(item, i)) count++;
        return count;
    }
    synchronized boolean hasPage(JSONObject item, int index) {
        try {
            long size = item.getJSONArray("sizes").getLong(index);
            File file = new File(directory(item.getString("id")), index + ".page");
            return size > 0 && file.isFile() && file.length() == size;
        } catch (Exception error) { return false; }
    }
    synchronized JSONObject prepare(JSONObject manga, JSONObject chapter, JSONArray pages) throws Exception {
        if (pages == null || pages.length() == 0) throw new IOException("Нет страниц для скачивания");
        for (int i = 0; i < pages.length(); i++) if (pages.getJSONObject(i).getString("url").length() == 0)
            throw new IOException("Неверный адрес страницы");
        String id = key(manga.optString("slug_url"), chapter);
        JSONObject previous = get(id);
        if (previous != null && pages.toString().equals(previous.getJSONArray("pages").toString())) {
            for (int i = 0; i < pages.length(); i++) {
                try { page(previous, i); }
                catch (IOException error) {
                    previous.getJSONArray("sizes").put(i, 0); previous.getJSONArray("hashes").put(i, "");
                    previous.put("complete", false);
                }
            }
            save(previous); return previous;
        }
        delete(id);
        File folder = directory(id);
        if (!folder.mkdirs() && !folder.isDirectory()) throw new IOException("Нет места для скачивания главы");
        JSONObject item = new JSONObject(); item.put("id", id); item.put("manga", new JSONObject(manga.toString()));
        item.put("chapter", new JSONObject(chapter.toString())); item.put("pages", new JSONArray(pages.toString()));
        JSONArray sizes = new JSONArray(), hashes = new JSONArray();
        for (int i = 0; i < pages.length(); i++) { sizes.put(0); hashes.put(""); }
        item.put("sizes", sizes); item.put("hashes", hashes); item.put("complete", false);
        item.put("saved_at", System.currentTimeMillis()); save(item); return item;
    }
    private void save(JSONObject item) throws Exception {
        atomic(new File(directory(item.getString("id")), "chapter.json"), item.toString().getBytes("UTF-8"));
    }
    synchronized void putPage(JSONObject item, int index, byte[] data) throws Exception {
        if (index < 0 || index >= item.getJSONArray("pages").length() || data.length == 0 || data.length > 20 * 1024 * 1024)
            throw new IOException("Неверная страница загрузки");
        atomic(new File(directory(item.getString("id")), index + ".page"), data);
        item.getJSONArray("sizes").put(index, data.length); item.getJSONArray("hashes").put(index, hash(data));
        item.put("complete", false); save(item);
    }
    synchronized byte[] page(JSONObject item, int index) throws Exception {
        if (!hasPage(item, index)) throw new IOException("Страница не сохранена. Скачай главу заново.");
        byte[] data = bytes(new File(directory(item.getString("id")), index + ".page"), 20 * 1024 * 1024);
        if (!hash(data).equals(item.getJSONArray("hashes").getString(index)))
            throw new IOException("Сохранённая страница повреждена. Скачай главу заново.");
        return data;
    }
    synchronized void finish(JSONObject item) throws Exception {
        for (int i = 0; i < item.getJSONArray("pages").length(); i++) page(item, i);
        item.put("complete", true);
        try { save(item); } catch (Exception error) { item.put("complete", false); throw error; }
    }
    synchronized void delete(String id) throws IOException {
        File folder = directory(id); File[] files = folder.listFiles();
        if (files != null) for (File file : files) {
            if (!file.getCanonicalFile().getParentFile().equals(folder.getCanonicalFile()) || file.isDirectory())
                throw new IOException("Неверный файл загрузки");
            if (!file.delete()) throw new IOException("Не удалось удалить загрузку");
        }
        if (folder.exists() && !folder.delete()) throw new IOException("Не удалось удалить загрузку");
    }
}
