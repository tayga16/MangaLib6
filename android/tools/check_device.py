"""Build an isolated diagnostic DEX with the APK's TLS/shrinking rules.

Usage: python android/tools/check_device.py
Push build/device-check/network.jar and assets/cacert.pem to /data/local/tmp,
then run ru.mangapad.legacy.DeviceNetworkCheck with Android's app_process.
No debugger, app data, credentials or application settings are involved.
"""
from pathlib import Path
import os
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/device-check'
JDK = Path(os.environ.get('JAVA_HOME', str(Path.home() / 'jdk-17/jdk-17.0.20.1+1')))
SDK = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'AppData/Local/Android/Sdk')))
API = ROOT / 'deps/android-2.3.3.jar'
JSON = ROOT / 'deps/json-20080701.jar'
LIBS = sorted((ROOT / 'deps').glob('bc*-1.83.jar'))
(OUT / 'classes').mkdir(parents=True, exist_ok=True)
cp = os.pathsep.join(map(str, [API, JSON, *LIBS]))
sources = [ROOT / 'src/ru/mangapad/legacy' / (name + '.java')
    for name in ('LegacyHttp', 'MangaApi', 'RequestDeadline')]
sources.append(ROOT / 'tests/DeviceNetworkCheck.java')
subprocess.run([str(JDK / 'bin/javac.exe'), '-encoding', 'UTF-8', '-source', '7', '-target', '7',
    '-Xlint:-options', '-cp', cp, '-d', str(OUT / 'classes'), *map(str, sources)], check=True)
with zipfile.ZipFile(OUT / 'input.jar', 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted((OUT / 'classes').rglob('*.class')):
        archive.write(path, path.relative_to(OUT / 'classes').as_posix())
rules = '\n'.join(line for line in (ROOT / 'proguard-rules.pro').read_text().splitlines()
    if not line.startswith(('-keep public class ru.mangapad.legacy.MainActivity',
        '-keep class ru.mangapad.legacy.PageRegion')))
(OUT / 'checks.pro').write_text(rules
    + '\n-keep public class ru.mangapad.legacy.DeviceNetworkCheck { public static void main(java.lang.String[]); }\n')
subprocess.run([str(JDK / 'bin/java.exe'), '-Xmx2g', '-cp', str(SDK / 'build-tools/34.0.0/lib/d8.jar'),
    'com.android.tools.r8.R8', '--release', '--min-api', '9', '--no-desugaring',
    '--lib', str(API), '--lib', str(JSON), '--lib', str(JDK), '--pg-conf', str(OUT / 'checks.pro'),
    '--output', str(OUT / 'network.jar'), str(OUT / 'input.jar'), *map(str, LIBS)], check=True)
print(OUT / 'network.jar')
