package ru.mangapad.legacy;

import java.io.*;
import java.security.MessageDigest;
import java.util.*;

/** Encoded originals for zoom, on disk rather than in the bitmap buffer. */
final class PageSources {
    private final File root;
    private final long limit;
    private File current;
    PageSources(File root, long limit) { this.root = root; this.limit = limit; }
    File file(String address) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(address.getBytes("UTF-8"));
            StringBuilder name = new StringBuilder();
            for (byte part : digest) name.append(String.format(Locale.US, "%02x", part & 255));
            return new File(root, name.toString() + ".image");
        } catch (Exception error) { throw new IllegalStateException(error); }
    }
    synchronized void pin(File file) { current = file; }
    synchronized byte[] read(String address) {
        File cached = file(address);
        long length = cached.length();
        if (length <= 0 || length > 12L * 1024 * 1024) return null;
        try {
            byte[] data = new byte[(int)length];
            DataInputStream input = new DataInputStream(new FileInputStream(cached));
            try { input.readFully(data); } finally { input.close(); }
            cached.setLastModified(System.currentTimeMillis());
            return data;
        } catch (IOException unavailable) { return null; }
    }
    synchronized void put(String address, byte[] data) throws IOException {
        if (!root.isDirectory() && !root.mkdirs()) throw new IOException("Нет места для исходника страницы");
        File target = file(address), temporary = new File(root, target.getName() + ".tmp");
        try {
            FileOutputStream output = new FileOutputStream(temporary);
            try { output.write(data); } finally { output.close(); }
            if (target.exists() && !target.delete()) throw new IOException("Не удалось обновить исходник");
            if (!temporary.renameTo(target)) throw new IOException("Не удалось сохранить исходник");
        } finally { temporary.delete(); }
        File[] files = root.listFiles(new FilenameFilter() { public boolean accept(File folder, String name) {
            return name.matches("[a-f0-9]{64}\\.image");
        } });
        if (files == null) return;
        Arrays.sort(files, new Comparator<File>() { public int compare(File a, File b) {
            return Long.valueOf(a.lastModified()).compareTo(Long.valueOf(b.lastModified()));
        } });
        long total = 0;
        for (File file : files) total += file.length();
        for (File file : files) {
            if (total <= limit) break;
            if (!file.equals(current) && !file.equals(target)) {
                long size = file.length(); if (file.delete()) total -= size;
            }
        }
    }
}
