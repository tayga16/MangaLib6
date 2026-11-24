"""Exercise actual legacy TLS client against a local TLS 1.2 fixture."""
from pathlib import Path
from datetime import datetime, timedelta, timezone
import gzip
import http.server
import os
import ssl
import subprocess
import threading
import time
import sys
import zipfile
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, ec
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/tls-fixture'
OUT.mkdir(parents=True, exist_ok=True)
now = datetime.now(timezone.utc)
root_key = (ec.generate_private_key(ec.SECP384R1()) if '--ec' in sys.argv
    else rsa.generate_private_key(public_exponent=65537, key_size=2048))
root_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'MangaLib test CA')])
root_cert = (x509.CertificateBuilder().subject_name(root_name).issuer_name(root_name)
    .public_key(root_key.public_key()).serial_number(x509.random_serial_number())
    .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=2))
    .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
    .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
    .sign(root_key, hashes.SHA256()))
key = (ec.generate_private_key(ec.SECP256R1()) if '--ec' in sys.argv
    else rsa.generate_private_key(public_exponent=65537, key_size=2048))
cert = (x509.CertificateBuilder()
    .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')]))
    .issuer_name(root_name).public_key(key.public_key()).serial_number(x509.random_serial_number())
    .not_valid_before(now - timedelta(days=2))
    .not_valid_after(now - timedelta(days=1) if '--expired' in sys.argv else now + timedelta(days=1))
    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
    .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]), critical=False)
    .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
    .add_extension(x509.KeyUsage(True, False, True, False, False, False, False, False, False), critical=True)
    .sign(root_key, hashes.SHA256()))
(OUT / 'ca.pem').write_bytes(root_cert.public_bytes(serialization.Encoding.PEM))
(OUT / 'server.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
(OUT / 'key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM,
    serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
untrusted_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
untrusted_root = (x509.CertificateBuilder().subject_name(root_name).issuer_name(root_name)
    .public_key(untrusted_key.public_key()).serial_number(x509.random_serial_number())
    .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=2))
    .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
    .sign(untrusted_key, hashes.SHA256()))
(OUT / 'untrusted.pem').write_bytes(untrusted_root.public_bytes(serialization.Encoding.PEM))
# An unrelated CA with an unknown public-key algorithm must not be decoded
# during startup or affect a valid chain. The wrong key with a matching issuer
# still exercises signature verification rather than trusting an issuer name.
unused_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Unused test CA')])
unused = (x509.CertificateBuilder().subject_name(unused_name).issuer_name(unused_name)
    .public_key(untrusted_key.public_key()).serial_number(x509.random_serial_number())
    .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=2))
    .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
    .sign(untrusted_key, hashes.SHA256()))
unused_der = unused.public_bytes(serialization.Encoding.DER)
rsa_oid = bytes.fromhex('06092a864886f70d010101')
assert unused_der.count(rsa_oid) == 1
unused_der = unused_der.replace(rsa_oid, bytes.fromhex('06092a864886f70d010163'))
unused_pem = x509.load_der_x509_certificate(unused_der).public_bytes(serialization.Encoding.PEM)
(OUT / 'unused.pem').write_bytes(unused_pem)
(OUT / 'mixed-ca.pem').write_bytes(unused_pem
    + untrusted_root.public_bytes(serialization.Encoding.PEM)
    + root_cert.public_bytes(serialization.Encoding.PEM))

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    retry_count = 0
    forbidden_count = 0
    api_primary_count = 0
    api_secondary_count = 0
    api_denied_count = 0
    api_slow_count = 0
    connection_count = 0
    negotiated_ciphers = []
    connection_lock = threading.Lock()
    image_compressed_count = 0
    image_good_count = 0
    def setup(self):
        super().setup()
        with Handler.connection_lock:
            Handler.connection_count += 1
            self.connection_id = Handler.connection_count
            Handler.negotiated_ciphers.append(self.connection.cipher()[0])
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path in ('/connection-id', '/silent-close', '/close'):
            data = str(self.connection_id).encode('ascii')
            self.send_response(200); self.send_header('Content-Length', str(len(data)))
            if self.path == '/close': self.send_header('Connection', 'keep-alive, close')
            self.end_headers(); self.wfile.write(data); self.wfile.flush()
            if self.path != '/connection-id': self.close_connection = True
            return
        if self.path == '/truncated':
            self.send_response(200); self.send_header('Content-Length', '100'); self.end_headers()
            self.wfile.write(b'short'); self.wfile.flush(); self.close_connection = True; return
        if self.path == '/ambiguous':
            self.send_response(200); self.send_header('Content-Length', '1')
            self.send_header('Content-Length', '2'); self.end_headers()
            self.wfile.write(b'xx'); self.wfile.flush(); return
        if self.path == '/no-content':
            self.send_response(204); self.end_headers(); return
        if self.path.startswith('/image-api/constants'):
            base = f'https://localhost:{self.server.server_port}'
            data = ('{"data":{"imageServers":['
                '{"id":"compress","url":"' + base + '/image-compressed","site_ids":[1]},'
                '{"id":"download","url":"' + base + '/image-good","site_ids":[1]}]}}').encode('utf-8')
            self.send_response(200); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        if self.path.startswith('/image-compressed/') or self.path.startswith('/image-good/'):
            if self.path.startswith('/image-compressed/'):
                Handler.image_compressed_count += 1
                data = b'\xff\xd8' + b'compressed fixture'
            else:
                Handler.image_good_count += 1
                data = (b'<html>unsupported</html>' if self.path.endswith('/unavailable')
                    else b'\xff\xd8' + b'original fixture')
            self.send_response(200); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        if self.path == '/slow-headers' or self.path.startswith('/api-slow/'):
            if self.path.startswith('/api-slow/'):
                Handler.api_slow_count += 1
            # Keep supplying bytes before SO_TIMEOUT expires. Only an absolute
            # deadline can stop this response.
            try:
                for byte in b'HTTP/1.1 200 OK\r\nX-Slow: ' + b'a' * 100:
                    self.wfile.write(bytes([byte])); self.wfile.flush(); time.sleep(.1)
            except (OSError, ssl.SSLError): pass
            return
        if self.path == '/slow-body':
            self.send_response(200); self.send_header('Content-Length', '100'); self.end_headers()
            try:
                for unused in range(100):
                    self.wfile.write(b'a'); self.wfile.flush(); time.sleep(.1)
            except (OSError, ssl.SSLError): pass
            return
        if self.path == '/stall':
            time.sleep(4)
            return
        if self.path.startswith('/api-primary/'):
            Handler.api_primary_count += 1
            self.send_response(502); self.send_header('Content-Length', '0'); self.end_headers(); return
        if self.path.startswith('/api-denied/'):
            Handler.api_denied_count += 1
            self.send_response(403); self.send_header('Content-Length', '0'); self.end_headers(); return
        if self.path.startswith('/api-secondary/'):
            Handler.api_secondary_count += 1
            data = b'{"data":[{"slug_url":"fixture","rus_name":"fixture"}]}'
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        if self.path == '/redirect':
            self.send_response(302); self.send_header('Location', '/gzip')
            self.send_header('Content-Length', '0'); self.end_headers(); return
        if self.path == '/retry':
            Handler.retry_count += 1
            if Handler.retry_count == 1:
                self.send_response(502); self.send_header('Content-Length', '0'); self.end_headers(); return
            data = b'retried'
        elif self.path == '/forbidden':
            Handler.forbidden_count += 1
            self.send_response(403); self.send_header('Content-Length', '0'); self.end_headers(); return
        elif self.path == '/chunked':
            self.send_response(200); self.send_header('Transfer-Encoding', 'chunked'); self.end_headers()
            self.wfile.write(b'7\r\nchunked\r\n4\r\n TLS\r\n0\r\nX-Fixture: trailer\r\n\r\n'); return
        else: data = gzip.compress(b'hello TLS')
        self.send_response(200)
        if self.path == '/gzip': self.send_header('Content-Encoding', 'gzip')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.minimum_version = tls.maximum_version = ssl.TLSVersion.TLSv1_2
# Prefer ChaCha at the server to verify that the legacy client really filters it
# while still negotiating authenticated AES with either RSA or EC certificates.
tls.set_ciphers('ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:'
    'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256')
tls.load_cert_chain(OUT / 'server.pem', OUT / 'key.pem')
sni = []
tls.set_servername_callback(lambda sock, name, context: sni.append(name))
server.socket = tls.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
other = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
other.socket = tls.wrap_socket(other.socket, server_side=True)
threading.Thread(target=other.serve_forever, daemon=True).start()
JDK = Path(os.environ.get('JAVA_HOME', str(Path.home() / 'jdk-17/jdk-17.0.20.1+1')))
cp = os.pathsep.join(str(p) for p in [ROOT / 'build/classes', ROOT / 'deps/json-20080701.jar',
    *sorted((ROOT / 'deps').glob('bc*-1.83.jar'))])
try:
    sources = [ROOT / 'src/ru/mangapad/legacy/LegacyHttp.java', ROOT / 'src/ru/mangapad/legacy/MangaApi.java',
        ROOT / 'src/ru/mangapad/legacy/RequestDeadline.java',
        ROOT / 'tests/TransportCheck.java']
    subprocess.run([str(JDK / 'bin/javac.exe'), '-encoding', 'UTF-8', '-cp', cp,
        '-d', str(ROOT / 'build/classes'), *map(str, sources)], check=True)
    if '--reuse-optimized' in sys.argv:
        cp = os.pathsep.join([str(OUT / 'optimized.jar'), str(ROOT / 'deps/json-20080701.jar')])
    elif '--optimized' in sys.argv:
        # Exercise the same shrinking/repackaging rules as the APK, rather than
        # accidentally validating only the complete, unoptimized BC jars.
        app = OUT / 'input.jar'
        with zipfile.ZipFile(app, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in (ROOT / 'build/classes').rglob('*.class'):
                if not path.name.startswith(('LegacyHttp', 'MangaApi', 'RequestDeadline', 'TransportCheck')): continue
                archive.write(path, path.relative_to(ROOT / 'build/classes').as_posix())
        rules = OUT / 'checks.pro'
        # Avoid R8 8.2 classfile signature metadata bug; DEX build retains it.
        base_rules = '\n'.join(line for line in (ROOT / 'proguard-rules.pro').read_text().splitlines()
            if not line.startswith(('-keepattributes', '-keep public class ru.mangapad.legacy.MainActivity')))
        rules.write_text(base_rules
            + '\n-dontoptimize\n-keep public class ru.mangapad.legacy.TransportCheck { public static void main(java.lang.String[]); }\n')
        sdk = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'AppData/Local/Android/Sdk')))
        optimized = OUT / 'optimized.jar'
        subprocess.run([str(JDK / 'bin/java.exe'), '-Xmx2g', '-cp', str(sdk / 'build-tools/34.0.0/lib/d8.jar'),
            'com.android.tools.r8.R8', '--classfile', '--release', '--no-desugaring',
            '--lib', str(JDK), '--lib', str(ROOT / 'deps/android-2.3.3.jar'),
            '--lib', str(ROOT / 'deps/json-20080701.jar'), '--pg-conf', str(rules),
            '--output', str(optimized), str(app), *map(str, sorted((ROOT / 'deps').glob('bc*-1.83.jar')))], check=True)
        cp = os.pathsep.join([str(optimized), str(ROOT / 'deps/json-20080701.jar')])
    port = server.server_port
    run = [str(JDK / 'bin/java.exe'), '-cp', cp, 'ru.mangapad.legacy.TransportCheck']
    if '--expired' in sys.argv:
        subprocess.run([*run, str(OUT / 'ca.pem'), '--reject', f'https://localhost:{port}', 'date'], check=True)
        sys.exit(0)
    subprocess.run([*run, str(ROOT / 'assets/cacert.pem'), '--roots'], check=True)
    subprocess.run([*run, str(OUT / 'unused.pem'), '--deferred-root'], check=True)
    subprocess.run([str(JDK / 'bin/java.exe'), '-cp', cp, 'ru.mangapad.legacy.TransportCheck',
        str(OUT / 'mixed-ca.pem'), '--fixture', f'https://localhost:{port}', f'https://127.0.0.1:{port}',
        f'https://localhost:{other.server_port}'], check=True)
    subprocess.run([*run, str(OUT / 'untrusted.pem'), '--reject', f'https://localhost:{port}', 'trust'], check=True)
    assert Handler.retry_count == 2 and Handler.forbidden_count == 1
    assert Handler.api_primary_count == 3, Handler.api_primary_count
    assert Handler.api_secondary_count == 2, Handler.api_secondary_count
    assert Handler.api_denied_count == 1, Handler.api_denied_count
    assert Handler.api_slow_count == 1, Handler.api_slow_count
    assert Handler.image_compressed_count == 1, Handler.image_compressed_count
    assert Handler.image_good_count == 4, Handler.image_good_count
    assert 'localhost' in sni
    assert Handler.negotiated_ciphers and all('AES' in cipher for cipher in Handler.negotiated_ciphers), Handler.negotiated_ciphers
    print('PASS: authenticated AES selected despite server preference for ChaCha20/Poly1305')
    print('PASS: certificate algorithm ' + ('EC' if '--ec' in sys.argv else 'RSA'))
finally:
    other.shutdown(); other.server_close()
    server.shutdown(); server.server_close()
