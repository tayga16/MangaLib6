package ru.mangapad.legacy;
import java.io.*;
import java.util.Arrays;
import org.json.*;

public class ChapterDownloadsCheck {
    private static void require(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        File root = new File(args[0]); ChapterDownloads store = new ChapterDownloads(root);
        JSONObject manga = new JSONObject("{\"slug_url\":\"../../test\",\"name\":\"Test\"}");
        JSONObject chapter = new JSONObject("{\"volume\":\"1\",\"number\":\"9.5\"}");
        JSONArray pages = new JSONArray("[{\"url\":\"/one.png\"},{\"url\":\"/two.png\"}]");
        byte[] first = new byte[] {1,2,3,4}, second = new byte[] {5,6,7,8};
        String id = ChapterDownloads.key(manga.optString("slug_url"), chapter); store.delete(id);
        JSONObject item = store.prepare(manga, chapter, pages);
        require(!store.complete(item) && store.list().size() == 1);
        store.putPage(item, 0, first);
        store = new ChapterDownloads(root); item = store.get(id);
        require(store.count(item) == 1 && store.ready(manga.optString("slug_url"), chapter) == null);
        require(Arrays.equals(first, store.page(item, 0)));
        boolean failed = false;
        try { store.finish(item); } catch (IOException error) { failed = true; }
        require(failed && !store.complete(item));
        store.putPage(item, 1, second); store.finish(item);
        store = new ChapterDownloads(root); item = store.ready(manga.optString("slug_url"), chapter);
        require(item != null && store.count(item) == 2 && Arrays.equals(second, store.page(item, 1)));
        // Same-size corruption must be detected, not silently displayed.
        FileOutputStream out = new FileOutputStream(new File(new File(root, id), "0.page"));
        out.write(second); out.close(); failed = false;
        try { store.page(item, 0); } catch (IOException error) { failed = true; }
        require(failed);
        item = store.prepare(manga, chapter, pages);
        require(!store.hasPage(item, 0) && store.hasPage(item, 1) && !store.complete(item));
        store.putPage(item, 0, first); store.finish(item);
        // Truncation makes a supposedly completed chapter unavailable.
        out = new FileOutputStream(new File(new File(root, id), "1.page")); out.write(1); out.close();
        require(store.ready(manga.optString("slug_url"), chapter) == null);
        store.putPage(item, 1, second); store.finish(item);
        JSONObject changed = store.prepare(manga, chapter, new JSONArray("[{\"url\":\"/changed.png\"}]"));
        require(!store.complete(changed) && store.count(changed) == 0);
        failed = false; try { store.delete("../escape"); } catch (IOException error) { failed = true; }
        require(failed); store.delete(id); require(store.list().isEmpty());
        System.out.println("PASS: partial download/relaunch/resume, complete commit, integrity, changed chapter, safe deletion");
    }
}
