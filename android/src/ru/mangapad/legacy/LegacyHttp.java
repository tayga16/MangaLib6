package ru.mangapad.legacy;

import java.io.*;
import java.net.*;
import java.security.*;
import java.security.cert.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.zip.GZIPInputStream;
import org.bouncycastle.tls.*;
import org.bouncycastle.tls.crypto.TlsCertificate;
import org.bouncycastle.tls.crypto.impl.bc.BcTlsCrypto;

/** TLS 1.2 with SNI, an up-to-date CA store and certificate/hostname validation.
 * Uses lightweight BC TLS rather than the Gingerbread system TLS provider. */
public final class LegacyHttp {
    // BC normally discovers algorithms by concatenating class names at runtime.
    // Explicit class references survive R8 shrinking and relocation, and helpers
    // share this private provider without replacing Android's built-in BC.
    private static final class LegacyCrypto extends org.bouncycastle.jcajce.util.BCJcaJceHelper {
        static final Provider READY = configure();
        private static Provider configure() {
            Provider provider = new LegacyCrypto().provider;
            org.bouncycastle.jce.provider.BouncyCastleProvider bc =
                (org.bouncycastle.jce.provider.BouncyCastleProvider)provider;
            org.bouncycastle.jcajce.provider.util.AsymmetricKeyInfoConverter rsa =
                new org.bouncycastle.jcajce.provider.asymmetric.rsa.KeyFactorySpi();
            bc.addKeyInfoConverter(org.bouncycastle.asn1.pkcs.PKCSObjectIdentifiers.rsaEncryption, rsa);
            bc.addKeyInfoConverter(org.bouncycastle.asn1.pkcs.PKCSObjectIdentifiers.id_RSASSA_PSS, rsa);
            bc.addKeyInfoConverter(org.bouncycastle.asn1.x509.X509ObjectIdentifiers.id_ea_rsa, rsa);
            bc.addKeyInfoConverter(org.bouncycastle.asn1.x9.X9ObjectIdentifiers.id_ecPublicKey,
                new org.bouncycastle.jcajce.provider.asymmetric.ec.KeyFactorySpi.EC());
            bc.addKeyInfoConverter(org.bouncycastle.asn1.x9.X9ObjectIdentifiers.id_dsa,
                new org.bouncycastle.jcajce.provider.asymmetric.dsa.KeyFactorySpi());
            service(provider, "KeyFactory", "RSA", org.bouncycastle.jcajce.provider.asymmetric.rsa.KeyFactorySpi.class);
            service(provider, "KeyFactory", "EC", org.bouncycastle.jcajce.provider.asymmetric.ec.KeyFactorySpi.EC.class);
            service(provider, "KeyFactory", "DSA", org.bouncycastle.jcajce.provider.asymmetric.dsa.KeyFactorySpi.class);
            signature(provider, "SHA1WITHRSA", "1.2.840.113549.1.1.5", org.bouncycastle.jcajce.provider.asymmetric.rsa.DigestSignatureSpi.SHA1.class);
            signature(provider, "SHA224WITHRSA", "1.2.840.113549.1.1.14", org.bouncycastle.jcajce.provider.asymmetric.rsa.DigestSignatureSpi.SHA224.class);
            signature(provider, "SHA256WITHRSA", "1.2.840.113549.1.1.11", org.bouncycastle.jcajce.provider.asymmetric.rsa.DigestSignatureSpi.SHA256.class);
            signature(provider, "SHA384WITHRSA", "1.2.840.113549.1.1.12", org.bouncycastle.jcajce.provider.asymmetric.rsa.DigestSignatureSpi.SHA384.class);
            signature(provider, "SHA512WITHRSA", "1.2.840.113549.1.1.13", org.bouncycastle.jcajce.provider.asymmetric.rsa.DigestSignatureSpi.SHA512.class);
            signature(provider, "SHA1WITHECDSA", "1.2.840.10045.4.1", org.bouncycastle.jcajce.provider.asymmetric.ec.SignatureSpi.ecDSA.class);
            signature(provider, "SHA224WITHECDSA", "1.2.840.10045.4.3.1", org.bouncycastle.jcajce.provider.asymmetric.ec.SignatureSpi.ecDSA224.class);
            signature(provider, "SHA256WITHECDSA", "1.2.840.10045.4.3.2", org.bouncycastle.jcajce.provider.asymmetric.ec.SignatureSpi.ecDSA256.class);
            signature(provider, "SHA384WITHECDSA", "1.2.840.10045.4.3.3", org.bouncycastle.jcajce.provider.asymmetric.ec.SignatureSpi.ecDSA384.class);
            signature(provider, "SHA512WITHECDSA", "1.2.840.10045.4.3.4", org.bouncycastle.jcajce.provider.asymmetric.ec.SignatureSpi.ecDSA512.class);
            signature(provider, "SHA1WITHDSA", "1.2.840.10040.4.3", org.bouncycastle.jcajce.provider.asymmetric.dsa.DSASigner.stdDSA.class);
            signature(provider, "SHA256WITHDSA", "2.16.840.1.101.3.4.3.2", org.bouncycastle.jcajce.provider.asymmetric.dsa.DSASigner.dsa256.class);
            signature(provider, "RSASSA-PSS", "1.2.840.113549.1.1.10", org.bouncycastle.jcajce.provider.asymmetric.rsa.PSSSignatureSpi.PSSwithRSA.class);
            service(provider, "Signature", "SHA256WITHRSAANDMGF1", org.bouncycastle.jcajce.provider.asymmetric.rsa.PSSSignatureSpi.SHA256withRSA.class);
            service(provider, "Signature", "SHA384WITHRSAANDMGF1", org.bouncycastle.jcajce.provider.asymmetric.rsa.PSSSignatureSpi.SHA384withRSA.class);
            service(provider, "Signature", "SHA512WITHRSAANDMGF1", org.bouncycastle.jcajce.provider.asymmetric.rsa.PSSSignatureSpi.SHA512withRSA.class);
            service(provider, "AlgorithmParameters", "PSS", org.bouncycastle.jcajce.provider.asymmetric.rsa.AlgorithmParametersSpi.PSS.class);
            service(provider, "AlgorithmParameters", "EC", org.bouncycastle.jcajce.provider.asymmetric.ec.AlgorithmParametersSpi.class);
            service(provider, "AlgorithmParameters", "DSA", org.bouncycastle.jcajce.provider.asymmetric.dsa.AlgorithmParametersSpi.class);
            service(provider, "CertificateFactory", "X.509", org.bouncycastle.jcajce.provider.asymmetric.x509.CertificateFactory.class);
            provider.put("Alg.Alias.CertificateFactory.X509", "X.509");
            return provider;
        }
        private static void service(Provider provider, String type, String name, Class<?> implementation) {
            provider.put(type + "." + name, implementation.getName());
        }
        private static void signature(Provider provider, String name, String oid, Class<?> implementation) {
            service(provider, "Signature", name, implementation);
            provider.put("Alg.Alias.Signature." + oid, name);
            provider.put("Alg.Alias.Signature.OID." + oid, name);
        }
    }
    private final Set<TrustAnchor> roots = new HashSet<TrustAnchor>();
    private final CertificateFactory certificates;
    // Use the legacy PKIX SPI directly: Android 2.3 lacks the Java 8 revocation APIs.
    private static final class LegacyCertificates extends CertificateFactory {
        LegacyCertificates() {
            super(new org.bouncycastle.jcajce.provider.asymmetric.x509.CertificateFactory(), null, "X.509");
        }
    }
    private static final class LegacyValidator extends CertPathValidator {
        LegacyValidator() { super(new org.bouncycastle.jce.provider.PKIXCertPathValidatorSpi(), null, "PKIX"); }
    }
    private static final int LIMIT = 12 * 1024 * 1024;
    private static final int MAX_IDLE = 4;
    private static final long IDLE_MILLIS = 30000, MAX_AGE_MILLIS = 120000;
    private static final ScheduledExecutorService IDLE_CLOCK = Executors.newSingleThreadScheduledExecutor(
        new ThreadFactory() { public Thread newThread(Runnable task) {
            Thread thread = new Thread(task, "mangalib-idle-connection");
            thread.setDaemon(true); return thread;
        } });
    private final LinkedHashMap<String,Connection> idle = new LinkedHashMap<String,Connection>();
    private final Set<Connection> connections = new HashSet<Connection>();
    private int poolGeneration;
    private boolean closed;

    private static final class Connection {
        final String key;
        final Socket socket = new Socket();
        final int generation;
        final long created = System.nanoTime();
        TlsClientProtocol protocol;
        InputStream input;
        OutputStream output;
        ScheduledFuture<?> expiry;
        int idleEpoch;
        Connection(String key, int generation) { this.key = key; this.generation = generation; }
    }

    // Each leased connection has one reader. Buffered TLS input belongs to the
    // connection, so bytes read ahead remain available for the next response.
    private synchronized Connection take(String key) throws IOException {
        if (closed) throw new InterruptedIOException("Сеть закрыта");
        Connection connection = idle.remove(key);
        if (connection != null) {
            connection.idleEpoch++;
            connection.expiry.cancel(false);
            if (!connection.socket.isClosed()
                    && TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - connection.created) < MAX_AGE_MILLIS) {
                return connection;
            }
            discard(connection);
        }
        connection = new Connection(key, poolGeneration);
        connections.add(connection);
        return connection;
    }
    private synchronized void discard(Connection connection) {
        if (idle.get(connection.key) == connection) idle.remove(connection.key);
        if (connection.expiry != null) connection.expiry.cancel(false);
        if (connections.remove(connection)) RequestDeadline.closeSocket(connection.socket);
    }
    private synchronized void keep(final Connection connection) {
        if (closed || connection.generation != poolGeneration || !connections.contains(connection)
                || connection.socket.isClosed()
                || TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - connection.created) >= MAX_AGE_MILLIS) {
            discard(connection); return;
        }
        Connection previous = idle.get(connection.key);
        if (previous != null) discard(previous);
        while (idle.size() >= MAX_IDLE) discard(idle.values().iterator().next());
        idle.put(connection.key, connection);
        final int epoch = ++connection.idleEpoch;
        connection.expiry = IDLE_CLOCK.schedule(new Runnable() { public void run() {
            synchronized (LegacyHttp.this) {
                if (idle.get(connection.key) == connection && connection.idleEpoch == epoch) discard(connection);
            }
        } }, IDLE_MILLIS, TimeUnit.MILLISECONDS);
    }
    public synchronized void closeIdle() {
        poolGeneration++;
        for (Connection connection : new ArrayList<Connection>(idle.values())) discard(connection);
    }
    public synchronized void close() {
        closed = true; poolGeneration++;
        for (Connection connection : new ArrayList<Connection>(connections)) discard(connection);
    }

    public LegacyHttp(InputStream caBundle) throws Exception {
        if (LegacyCrypto.READY == null) throw new CertificateException("Не удалось загрузить проверку сертификатов");
        certificates = new LegacyCertificates();
        try {
            for (java.security.cert.Certificate cert : certificates.generateCertificates(caBundle)) {
                // Keep the encoded certificates. PKIX reads the key only after
                // matching an issuer, then verifies the chain's signatures.
                // BC's RSA key validation for every bundled CA can take minutes
                // on Gingerbread and block all requests behind initialization.
                roots.add(new TrustAnchor((X509Certificate)cert, null));
            }
        } finally { caBundle.close(); }
        if (roots.isEmpty()) throw new CertificateException("Пустой список сертификатов");
    }

    static boolean matchesHost(String host, String pattern) {
        host = host.toLowerCase(Locale.US);
        pattern = pattern.toLowerCase(Locale.US);
        if (pattern.startsWith("*.")) {
            String suffix = pattern.substring(1);
            return suffix.indexOf('.', 1) > 0 && host.endsWith(suffix)
                && host.substring(0, host.length() - suffix.length()).indexOf('.') < 0
                && host.length() > suffix.length();
        }
        return host.equals(pattern);
    }

    private void verify(String host, TlsServerCertificate server) throws IOException {
        try {
            TlsCertificate[] peer = server.getCertificate().getCertificateList();
            if (peer.length == 0) throw new CertificateException("Нет сертификата сервера");
            List<X509Certificate> chain = new ArrayList<X509Certificate>();
            for (TlsCertificate cert : peer) {
                chain.add((X509Certificate)certificates.generateCertificate(
                    new ByteArrayInputStream(cert.getEncoded())));
            }
            X509Certificate leaf = chain.get(0);
            leaf.checkValidity();
            boolean hostname = false;
            Collection<List<?>> names = leaf.getSubjectAlternativeNames();
            if (names != null) for (List<?> name : names) {
                if (Integer.valueOf(2).equals(name.get(0)) && name.get(1) instanceof String
                        && matchesHost(host, (String)name.get(1))) hostname = true;
            }
            if (!hostname) throw new CertificateException("Сертификат не соответствует " + host);
            List<String> usage = leaf.getExtendedKeyUsage();
            if (usage != null && !usage.contains("1.3.6.1.5.5.7.3.1")
                    && !usage.contains("2.5.29.37.0")) {
                throw new CertificateException("Сертификат не предназначен для HTTPS");
            }
            // An included root must not be part of the path supplied to PKIX.
            if (chain.size() > 1) {
                X509Certificate last = chain.get(chain.size() - 1);
                for (TrustAnchor anchor : roots) if (last.equals(anchor.getTrustedCert())) {
                    chain.remove(chain.size() - 1);
                    break;
                }
            }
            PKIXParameters params = new PKIXParameters(roots);
            params.setRevocationEnabled(false);
            new LegacyValidator().validate(
                certificates.generateCertPath(chain), params);
        } catch (Exception error) {
            boolean dateError = false;
            for (Throwable cause = error; cause != null; cause = cause.getCause()) {
                if (cause instanceof CertificateExpiredException || cause instanceof CertificateNotYetValidException) {
                    dateError = true;
                    break;
                }
            }
            throw new IOException("Не удалось проверить сертификат. "
                + (dateError ? "Проверь дату устройства: " : "Причина: ") + error.getMessage(), error);
        }
    }

    static final class HttpError extends IOException {
        final int status;
        HttpError(int status) {
            this(status, null, null);
        }
        HttpError(int status, String host, String server) {
            super(message(status, host, server));
            this.status = status;
        }
        private static String message(int status, String host, String server) {
            String detail = status == 403 ? "сайт ограничил доступ" : status == 429
                ? "слишком много запросов. Повтори позже."
                : status == 502 ? "шлюз сайта не получил ответ сервера"
                : "сервер временно недоступен. Повтори позже.";
            String source = host == null ? "" : " · " + host;
            if (server != null && server.length() > 0) source += " · " + server;
            return "HTTP " + status + source + ": " + detail;
        }
    }

    static boolean retryable(IOException error) {
        if (error instanceof HttpError) {
            int status = ((HttpError)error).status;
            return status == 502 || status == 503 || status == 504;
        }
        return error instanceof SocketTimeoutException || error instanceof SocketException
            || error instanceof EOFException;
    }

    public byte[] get(String address) throws IOException {
        RequestDeadline parent = RequestDeadline.current();
        RequestDeadline deadline = new RequestDeadline(parent == null ? 30000 : Math.min(30000, parent.remainingMillis()));
        try {
        for (int attempt = 0; ; attempt++) {
            deadline.remainingMillis();
            try { return get(address, 0, deadline, parent); }
            catch (IOException error) {
                deadline.remainingMillis();
                if (attempt >= 1 || !retryable(error)) throw error;
                try { Thread.sleep(500); }
                catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt(); throw new InterruptedIOException("Загрузка отменена");
                }
            }
        }
        } finally { deadline.cancel(); }
    }

    // API failover handles its own bounded attempts across two hosts.
    byte[] getOnce(String address) throws IOException {
        return getOnce(address, 12000);
    }
    byte[] getOnce(String address, int milliseconds) throws IOException {
        RequestDeadline parent = RequestDeadline.current();
        RequestDeadline deadline = new RequestDeadline(parent == null ? milliseconds : Math.min(milliseconds, parent.remainingMillis()));
        try { return get(address, 0, deadline, parent); }
        finally { deadline.cancel(); }
    }

    private byte[] get(String address, int redirects, RequestDeadline deadline, RequestDeadline parent) throws IOException {
        deadline.remainingMillis();
        if (redirects > 4) throw new IOException("Слишком много перенаправлений");
        final URL url = new URL(address);
        if (!"https".equals(url.getProtocol()) || url.getUserInfo() != null
                || url.getHost().length() == 0) throw new IOException("Нужен адрес HTTPS");
        final String host = url.getHost();
        int port = url.getPort() < 0 ? 443 : url.getPort();
        Response response;
        for (int attempt = 0; ; attempt++) {
            Connection connection = take(host.toLowerCase(Locale.US) + ":" + port);
            boolean reused = connection.protocol != null;
            try { response = exchange(url, connection, deadline, parent); break; }
            catch (IOException error) {
                if (parent != null) parent.remainingMillis();
                deadline.remainingMillis();
                // The peer may have dropped an idle connection without notice.
                // Reconnect once, within the original deadline, for safe GETs.
                if (!reused || attempt != 0 || error instanceof HttpError
                        || !(retryable(error) || error instanceof TlsNoCloseNotifyException)) throw error;
            }
        }
        if (response.redirect != null) return get(response.redirect, redirects + 1, deadline, parent);
        return response.bytes;
    }

    private static final class Response {
        final byte[] bytes;
        final String redirect;
        Response(byte[] bytes, String redirect) { this.bytes = bytes; this.redirect = redirect; }
    }

    private Response exchange(final URL url, Connection connection,
            RequestDeadline deadline, RequestDeadline parent) throws IOException {
        final String host = url.getHost();
        int port = url.getPort() < 0 ? 443 : url.getPort();
        Socket socket = connection.socket;
        boolean reusable = false;
        String redirect = null;
        try {
            deadline.attach(socket);
            if (parent != null) parent.attach(socket);
            socket.setSoTimeout(Math.min(10000, deadline.remainingMillis()));
            if (connection.protocol == null) {
            InetAddress resolved = deadline.resolve(host);
            socket.connect(new InetSocketAddress(resolved, port), Math.min(10000, deadline.remainingMillis()));
            socket.setSoTimeout(Math.min(10000, deadline.remainingMillis()));
            socket.setTcpNoDelay(true);
            TlsClientProtocol protocol = new TlsClientProtocol(socket.getInputStream(), socket.getOutputStream());
            protocol.connect(new DefaultTlsClient(new BcTlsCrypto(new SecureRandom()) {
                public boolean hasEncryptionAlgorithm(int algorithm) {
                    // Poly1305's long arithmetic was a hot path on the HTC's Dalvik.
                    // Keep the default authenticated AES suites and certificate checks.
                    return algorithm != EncryptionAlgorithm.CHACHA20_POLY1305
                        && super.hasEncryptionAlgorithm(algorithm);
                }
            }) {
                public ProtocolVersion[] getProtocolVersions() {
                    return new ProtocolVersion[] { ProtocolVersion.TLSv12 };
                }
                protected Vector getSNIServerNames() {
                    Vector names = new Vector();
                    try { names.add(new ServerName(NameType.host_name, host.getBytes("UTF-8"))); }
                    catch (UnsupportedEncodingException impossible) { throw new RuntimeException(impossible); }
                    return names;
                }
                public TlsAuthentication getAuthentication() {
                    return new TlsAuthentication() {
                        public void notifyServerCertificate(TlsServerCertificate cert) throws IOException {
                            verify(host, cert);
                        }
                        public TlsCredentials getClientCredentials(CertificateRequest request) { return null; }
                    };
                }
            });
            connection.protocol = protocol;
            connection.input = new BufferedInputStream(protocol.getInputStream(), 8192);
            connection.output = protocol.getOutputStream();
            }
            String path = url.getFile().length() == 0 ? "/" : url.getFile();
            if (path.indexOf('\r') >= 0 || path.indexOf('\n') >= 0) throw new IOException("Неверный адрес");
            String request = "GET " + path + " HTTP/1.1\r\nHost: " + host
                + (port == 443 ? "" : ":" + port)
                + "\r\nUser-Agent: Mozilla/5.0 (Linux; Android 2.3.3) OldLib/0.1.0\r\n"
                + "Site-Id: 1\r\nReferer: https://mangalib.me/\r\nOrigin: https://mangalib.me\r\n"
                + "Accept: application/json, image/jpeg, image/png, */*\r\n"
                + "Accept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";
            OutputStream output = connection.output;
            output.write(request.getBytes("UTF-8")); output.flush();
            InputStream input = connection.input;
            String status = line(input);
            String[] parts = status.split(" ", 3);
            if (parts.length < 2) throw new IOException("Неверный ответ сервера");
            if (!"HTTP/1.1".equals(parts[0]) && !"HTTP/1.0".equals(parts[0])) throw new IOException("Неверный HTTP-протокол");
            int code;
            try { code = Integer.parseInt(parts[1]); }
            catch (NumberFormatException error) { throw new IOException("Неверный HTTP-статус"); }
            Map<String,String> headers = new HashMap<String,String>();
            for (int n = 0; ; n++) {
                String header = line(input);
                if (header.length() == 0) break;
                if (n >= 100) throw new IOException("Слишком много HTTP-заголовков");
                int colon = header.indexOf(':');
                if (colon <= 0) throw new IOException("Неверный HTTP-заголовок");
                String name = header.substring(0, colon).toLowerCase(Locale.US);
                String value = header.substring(colon + 1).trim();
                if (headers.containsKey(name)) {
                    if ("content-length".equals(name)) {
                        if (!headers.get(name).equals(value)) throw new IOException("Разные размеры HTTP-ответа");
                    } else headers.put(name, headers.get(name) + "," + value);
                } else headers.put(name, value);
            }
            String transfer = headers.get("transfer-encoding");
            boolean framed = (transfer == null && headers.containsKey("content-length"))
                || "chunked".equalsIgnoreCase(transfer);
            boolean persistent = !hasToken(headers.get("connection"), "close")
                && ("HTTP/1.1".equals(parts[0]) || hasToken(headers.get("connection"), "keep-alive"));
            if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                String location = headers.get("location");
                if (location == null) throw new IOException("Нет адреса перенаправления");
                redirect = new URL(url, location).toExternalForm();
                if (framed) { readBody(input, headers); reusable = persistent; }
                return new Response(null, redirect);
            } else {
                if (code < 200 || code >= 300) throw new HttpError(code, host, headers.get("server"));
                // 204 has no message body even without Content-Length.
                byte[] bytes = code == 204 ? new byte[0] : readBody(input, headers);
                if ("gzip".equalsIgnoreCase(headers.get("content-encoding"))) {
                    bytes = readAll(new GZIPInputStream(new ByteArrayInputStream(bytes)), LIMIT);
                }
                reusable = persistent && (framed || code == 204);
                return new Response(bytes, null);
            }
        } catch (IOException error) {
            if (parent != null) parent.remainingMillis();
            deadline.remainingMillis();
            throw error;
        } finally {
            boolean live = deadline.release(socket);
            if (parent != null) live = parent.release(socket) && live;
            if (reusable && live) keep(connection); else discard(connection);
        }
    }

    private static boolean hasToken(String value, String token) {
        if (value != null) for (String part : value.split(",")) if (token.equalsIgnoreCase(part.trim())) return true;
        return false;
    }

    static String line(InputStream input) throws IOException {
        ByteArrayOutputStream result = new ByteArrayOutputStream();
        for (;;) {
            int value = input.read();
            if (value < 0) throw new EOFException("Неполный HTTP-ответ");
            if (value == '\n') break;
            if (result.size() >= 8192) throw new IOException("Слишком длинный заголовок");
            result.write(value);
        }
        byte[] bytes = result.toByteArray();
        int size = bytes.length;
        if (size > 0 && bytes[size - 1] == '\r') size--;
        return new String(bytes, 0, size, "ISO-8859-1");
    }

    static byte[] readBody(InputStream input, Map<String,String> headers) throws IOException {
        String transfer = headers.get("transfer-encoding");
        if (transfer != null && !"chunked".equalsIgnoreCase(transfer)) throw new IOException("Неподдерживаемое HTTP-кодирование");
        if (transfer != null) {
            ByteArrayOutputStream result = new ByteArrayOutputStream();
            for (;;) {
                String sizeLine = line(input).split(";", 2)[0].trim();
                long size;
                try { size = Long.parseLong(sizeLine, 16); }
                catch (NumberFormatException error) { throw new IOException("Неверный HTTP-блок"); }
                if (size < 0 || size > LIMIT - result.size()) throw new IOException("Ответ слишком большой");
                if (size == 0) {
                    for (int n = 0; ; n++) {
                        String trailer = line(input);
                        if (trailer.length() == 0) break;
                        if (n >= 100 || trailer.indexOf(':') <= 0) throw new IOException("Неверный завершающий HTTP-заголовок");
                    }
                    break;
                }
                copyExact(input, result, (int)size);
                if (!"".equals(line(input))) throw new IOException("Неверный разделитель HTTP-блока");
            }
            return result.toByteArray();
        }
        String length = headers.get("content-length");
        if (length != null) {
            long count;
            try { count = Long.parseLong(length); }
            catch (NumberFormatException error) { throw new IOException("Неверный размер ответа"); }
            if (count < 0 || count > LIMIT) throw new IOException("Ответ слишком большой");
            ByteArrayOutputStream result = new ByteArrayOutputStream();
            copyExact(input, result, (int)count);
            return result.toByteArray();
        }
        return readAll(input, LIMIT);
    }

    private static void copyExact(InputStream input, OutputStream output, int remaining) throws IOException {
        byte[] buffer = new byte[8192];
        while (remaining > 0) {
            int read = input.read(buffer, 0, Math.min(buffer.length, remaining));
            if (read < 0) throw new EOFException("Загрузка прервана");
            output.write(buffer, 0, read); remaining -= read;
        }
    }

    static byte[] readAll(InputStream input, int limit) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int read;
        while ((read = input.read(buffer)) != -1) {
            if (read > limit - output.size()) throw new IOException("Ответ слишком большой");
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }
}
