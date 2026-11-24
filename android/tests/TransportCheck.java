package ru.mangapad.legacy;

import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.net.SocketTimeoutException;
import org.json.*;

public final class TransportCheck {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static String connection(LegacyHttp http, String base) throws IOException {
        return new String(http.getOnce(base + "/connection-id"), "ASCII");
    }
    public static void main(String[] args) throws Exception {
        check(LegacyHttp.matchesHost("api.cdnlibs.org", "*.cdnlibs.org"), "wildcard");
        check(!LegacyHttp.matchesHost("x.api.cdnlibs.org", "*.cdnlibs.org"), "nested wildcard");
        check(!LegacyHttp.matchesHost("cdnlibs.org", "*.cdnlibs.org"), "bare domain");
        check(!LegacyHttp.matchesHost("evilcdnlibs.org", "*.cdnlibs.org"), "suffix attack");
        Map<String,String> headers = new HashMap<String,String>(); headers.put("transfer-encoding", "chunked");
        byte[] result = LegacyHttp.readBody(new ByteArrayInputStream("3\r\nabc\r\n2;ext=yes\r\nde\r\n0\r\n\r\n".getBytes("ASCII")), headers);
        check("abcde".equals(new String(result, "ASCII")), "chunk decoding");
        headers.clear(); headers.put("content-length", "5");
        try {
            LegacyHttp.readBody(new ByteArrayInputStream("abc".getBytes("ASCII")), headers);
            throw new AssertionError("truncated response accepted");
        } catch (EOFException expected) { }
        check(LegacyHttp.retryable(new LegacyHttp.HttpError(502)), "502 retry");
        check(!LegacyHttp.retryable(new LegacyHttp.HttpError(403)), "403 must not retry");
        check(!LegacyHttp.retryable(new LegacyHttp.HttpError(429)), "429 must not retry");
        check(MangaApi.supportedImage(new byte[] {(byte)255, (byte)216, 0, 0, 0, 0, 0, 0}), "JPEG");
        check(!MangaApi.supportedImage("<html>bad response</html>".getBytes("ASCII")), "HTML image rejection");
        LegacyHttp http = new LegacyHttp(new FileInputStream(args[0]));
        if (args.length > 1 && "--roots".equals(args[1])) {
            System.out.println("PASS: bundled trust anchors loaded without eagerly decoding all public keys");
            http.close();
            return;
        }
        if (args.length > 1 && "--deferred-root".equals(args[1])) {
            java.security.cert.CertificateFactory factory = new java.security.cert.CertificateFactory(
                    new org.bouncycastle.jcajce.provider.asymmetric.x509.CertificateFactory(), null, "X.509") { };
            java.security.cert.Certificate unused;
            FileInputStream input = new FileInputStream(args[0]);
            try { unused = factory.generateCertificate(input); } finally { input.close(); }
            check(unused.getPublicKey() == null, "fixture must have an unsupported unused public key");
            System.out.println("PASS: unused root public key is deferred during transport initialization");
            http.close();
            return;
        }
        if (args.length > 1 && "--reject".equals(args[1])) {
            try { http.get(args[2] + "/gzip"); throw new AssertionError("invalid certificate accepted"); }
            catch (IOException expected) {
                check(expected.getMessage().contains("сертификат"), "certificate validation error");
                boolean date = "date".equals(args[3]);
                check(expected.getMessage().contains("Проверь дату") == date, "date hint only for date errors");
                boolean reason = false;
                for (Throwable cause = expected; cause != null; cause = cause.getCause()) {
                    if (date && cause instanceof java.security.cert.CertificateExpiredException) reason = true;
                    if (!date && cause instanceof java.security.cert.CertPathValidatorException) reason = true;
                }
                check(reason, "expected certificate rejection reason");
            }
            System.out.println("PASS: certificate rejected: " + args[3]);
            return;
        }
        if (args.length > 1 && "--fixture".equals(args[1])) {
            String base = args[2];
            String first = connection(http, base);
            check("hello TLS".equals(new String(http.get(base + "/gzip"), "UTF-8")), "TLS gzip");
            check("chunked TLS".equals(new String(http.get(base + "/chunked"), "UTF-8")), "TLS chunks");
            check("hello TLS".equals(new String(http.get(base + "/redirect"), "UTF-8")), "TLS redirect");
            check(http.getOnce(base + "/no-content").length == 0, "204 without length");
            check(first.equals(connection(http, base)), "same TCP/TLS connection for length, gzip, chunk trailers, redirect and 204");
            String other = connection(http, args[4]);
            check(!first.equals(other), "different HTTPS port has separate connection");
            check(first.equals(connection(http, base)), "switching servers retains API connection");
            check(first.equals(new String(http.getOnce(base + "/silent-close"), "ASCII")), "stale fixture reused");
            String reconnected = connection(http, base);
            check(!first.equals(reconnected), "silently closed socket reconnects in getOnce");
            check(reconnected.equals(new String(http.getOnce(base + "/close"), "ASCII")), "explicit close reused before response");
            String afterClose = connection(http, base);
            check(!reconnected.equals(afterClose), "Connection close socket discarded");
            try { http.getOnce(base + "/truncated"); throw new AssertionError("truncated TLS body accepted"); }
            catch (IOException expected) { }
            check(!afterClose.equals(connection(http, base)), "truncated response not pooled");
            try { http.getOnce(base + "/ambiguous"); throw new AssertionError("ambiguous length accepted"); }
            catch (IOException expected) { check(expected.getMessage().contains("Разные размеры"), "framing error"); }
            connection(http, base);
            http.closeIdle();
            check(!other.equals(connection(http, args[4])), "closeIdle closes all origins");
            System.out.println("PASS: persistent HTTPS, chunk trailers, separate ports, silent reconnect, server close, truncated/ambiguous responses discarded");
            check("retried".equals(new String(http.get(base + "/retry"), "UTF-8")), "transient retry");
            try { http.get(base + "/forbidden"); throw new AssertionError("403 accepted"); }
            catch (LegacyHttp.HttpError expected) { check(expected.status == 403, "403 status"); }
            try { http.get(args[3] + "/gzip"); throw new AssertionError("wrong hostname accepted"); }
            catch (IOException expected) { check(expected.getMessage().contains("сертификат"), "hostname validation error"); }
            MangaApi fallback = new MangaApi(http, new String[] { base + "/api-primary", base + "/api-secondary" });
            check(fallback.search("fixture").length() == 1, "502 falls back to second API");
            check(fallback.search("fixture again").length() == 1, "successful API remembered");
            MangaApi denied = new MangaApi(http, new String[] { base + "/api-denied", base + "/api-secondary" });
            try { denied.search("fixture"); throw new AssertionError("API 403 accepted"); }
            catch (LegacyHttp.HttpError expected) { check(expected.status == 403, "API 403 stops failover"); }
            MangaApi broken = new MangaApi(http, new String[] { base + "/api-primary", base + "/api-primary" });
            try { broken.search("fixture"); throw new AssertionError("API 502 accepted"); }
            catch (IOException expected) {
                check(expected.getMessage().contains("502"), "API 502 shown");
                check(expected.getMessage().contains("localhost"), "error includes host");
                check(expected.getMessage().contains("Резервный API"), "both API errors shown");
            }
            System.out.println("PASS: API fallback on 502, remembered host, bounded failures, 403 stops fallback");
            MangaApi images = new MangaApi(http, new String[] { base + "/image-api" });
            check(new String(images.page(new JSONObject("{\"url\":\"page1\"}")), "ISO-8859-1").endsWith("original fixture"),
                "original preferred even when compressed server is valid and advertised first");
            check(new String(images.page(new JSONObject("{\"url\":\"page2\"}")), "ISO-8859-1").endsWith("original fixture"),
                "working original server remembered");
            check(new String(images.page(new JSONObject("{\"url\":\"unavailable\"}")), "ISO-8859-1").endsWith("compressed fixture"),
                "unsupported original falls back to compressed copy");
            check(new String(images.page(new JSONObject("{\"url\":\"recovered\"}")), "ISO-8859-1").endsWith("original fixture"),
                "compressed fallback does not lock subsequent pages to lower quality");
            System.out.println("PASS: original image preference, supported fallback and original recovery");
            for (String slow : new String[] { "/slow-headers", "/slow-body", "/stall" }) {
                long start = System.nanoTime();
                try { http.getOnce(base + slow, 1200); throw new AssertionError("slow response accepted: " + slow); }
                catch (SocketTimeoutException expected) { }
                long elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);
                check(elapsed >= 1000 && elapsed < 3500, "absolute deadline: " + slow + " " + elapsed);
            }
            RequestDeadline shortSearch = new RequestDeadline(1200);
            RequestDeadline.enter(shortSearch);
            long searchStart = System.nanoTime();
            try {
                new MangaApi(http, new String[] { base + "/api-slow", base + "/api-slow" }).search("slow");
                throw new AssertionError("stalled search accepted");
            } catch (SocketTimeoutException expected) { }
            finally { RequestDeadline.leave(); shortSearch.cancel(); }
            check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - searchStart) < 3500, "entire search deadline");
            final LegacyHttp transport = http;
            final String address = base;
            final RequestDeadline cancelled = new RequestDeadline(10000);
            final CountDownLatch started = new CountDownLatch(1);
            ExecutorService queue = Executors.newSingleThreadExecutor();
            try {
                Future<?> old = queue.submit(new Runnable() { public void run() {
                    RequestDeadline.enter(cancelled);
                    started.countDown();
                    try { transport.getOnce(address + "/stall"); }
                    catch (IOException expected) { }
                    finally { RequestDeadline.leave(); cancelled.cancel(); }
                } });
                check(started.await(2, TimeUnit.SECONDS), "old request started");
                Thread.sleep(300);
                cancelled.cancel(); old.cancel(true);
                Future<byte[]> fresh = queue.submit(new Callable<byte[]>() { public byte[] call() throws Exception {
                    return transport.getOnce(address + "/gzip");
                } });
                check("hello TLS".equals(new String(fresh.get(3, TimeUnit.SECONDS), "UTF-8")),
                    "cancelled request frees queue for new search");
            } finally { cancelled.cancel(); queue.shutdownNow(); }
            System.out.println("PASS: stalled responses and slow headers/body stop; search deadline; cancellation frees queue");
            System.out.println("PASS: TLS 1.2, SNI, trusted chain, hostname rejection, gzip, chunks, redirects, retry, 403, image formats");
            http.close();
            try { connection(http, base); throw new AssertionError("closed transport used"); }
            catch (InterruptedIOException expected) { }
            return;
        }
        MangaApi api = new MangaApi(http);
        JSONArray titles = api.search("chainsaw");
        check(titles.length() > 0, "search results");
        JSONObject selected = titles.getJSONObject(0);
        for (int i = 0; i < titles.length(); i++) {
            JSONObject item = titles.getJSONObject(i);
            if ("chainsaw-man".equals(item.optString("slug"))) selected = item;
        }
        String slug = selected.getString("slug_url");
        api.title(slug);
        JSONArray chapters = api.chapters(slug);
        check(chapters.length() > 0, "chapter list");
        JSONArray pages = api.chapter(slug, chapters.getJSONObject(0));
        check(pages.length() > 0, "page list");
        byte[] image = api.page(pages.getJSONObject(0));
        check(image.length > 1000, "page bytes");
        System.out.println("PASS: host validation, HTTP framing, live search, title, chapters, chapter, image: "
            + slug + ", " + chapters.length() + " chapters, " + pages.length() + " pages, " + image.length + " image bytes");
        if (args.length > 1) {
            FileOutputStream output = new FileOutputStream(args[1]);
            try { output.write(image); } finally { output.close(); }
        }
    }
}
