package ru.mangapad.legacy;

import java.text.ParsePosition;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import org.json.JSONArray;
import org.json.JSONObject;

/** Publication day of the first translation, as returned by the catalog. */
final class ChapterMetadata {
    static String publicationDate(JSONObject chapter) {
        if (chapter == null) return "";
        JSONArray branches = chapter.optJSONArray("branches");
        JSONObject branch = branches == null ? null : branches.optJSONObject(0);
        String date = day(branch == null ? "" : branch.optString("created_at"));
        return date.length() > 0 ? date : day(chapter.optString("created_at"));
    }
    static String publicationLabel(JSONObject chapter) {
        String date = publicationDate(chapter);
        return date.length() == 0 ? "Дата публикации не указана" : "Опубликована: " + date;
    }
    private static String day(String timestamp) {
        if (timestamp.length() < 10) return "";
        String day = timestamp.substring(0, 10);
        if (!day.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")) return "";
        SimpleDateFormat parser = new SimpleDateFormat("yyyy-MM-dd", Locale.US);
        parser.setTimeZone(TimeZone.getTimeZone("UTC")); parser.setLenient(false);
        ParsePosition position = new ParsePosition(0);
        Date parsed = parser.parse(day, position);
        if (parsed == null || position.getIndex() != day.length() || !day.equals(parser.format(parsed))) return "";
        return day.substring(8, 10) + "." + day.substring(5, 7) + "." + day.substring(0, 4);
    }
}
