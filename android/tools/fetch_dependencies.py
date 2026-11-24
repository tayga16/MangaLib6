"""Fetch pinned legacy Android build dependencies from upstream HTTPS URLs."""
from pathlib import Path
import concurrent.futures
import hashlib
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ITEMS = {
    'bcprov-jdk15to18-1.83.jar': 'https://repo.maven.apache.org/maven2/org/bouncycastle/bcprov-jdk15to18/1.83/bcprov-jdk15to18-1.83.jar',
    'bctls-jdk15to18-1.83.jar': 'https://repo.maven.apache.org/maven2/org/bouncycastle/bctls-jdk15to18/1.83/bctls-jdk15to18-1.83.jar',
    'bcutil-jdk15to18-1.83.jar': 'https://repo.maven.apache.org/maven2/org/bouncycastle/bcutil-jdk15to18/1.83/bcutil-jdk15to18-1.83.jar',
    'android-2.3.3.jar': 'https://repo.maven.apache.org/maven2/com/google/android/android/2.3.3/android-2.3.3.jar',
    'json-20080701.jar': 'https://repo.maven.apache.org/maven2/org/json/json/20080701/json-20080701.jar',
    'cacert.pem': 'https://curl.se/ca/cacert.pem',
}

def fetch(item):
    name, url = item
    target = ROOT / ('assets' if name == 'cacert.pem' else 'deps') / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        with urllib.request.urlopen(url, timeout=45) as response:
            data = response.read()
        if name.endswith('.jar'):
            import io
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                if archive.testzip():
                    raise RuntimeError('Corrupt dependency: ' + name)
        elif b'BEGIN CERTIFICATE' not in data:
            raise RuntimeError('Invalid CA bundle')
        target.write_bytes(data)
    return name, hashlib.sha256(target.read_bytes()).hexdigest()

if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        results = list(pool.map(fetch, ITEMS.items()))
    (ROOT / 'dependencies.sha256').write_text(
        ''.join(digest + '  ' + name + '\n' for name, digest in results), encoding='ascii')
    for name, digest in results:
        print(name, digest)
