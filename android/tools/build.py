"""Small reproducible legacy APK build: javac, R8, aapt, zipalign, apksigner."""
import os
from pathlib import Path
import shutil
import subprocess
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SDK = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'AppData/Local/Android/Sdk')))
JDK = Path(os.environ.get('JAVA_HOME', str(Path.home() / 'jdk-17/jdk-17.0.20.1+1')))
TOOLS = SDK / 'build-tools/34.0.0'
BUILD = ROOT / 'build'
API = ROOT / 'deps/android-2.3.3.jar'
JSON = ROOT / 'deps/json-20080701.jar'
LIBS = sorted((ROOT / 'deps').glob('bc*-1.83.jar'))

def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)

if __name__ == '__main__':
    # Remove obsolete app classes only after checking the precise build directory.
    class_dir = (BUILD / 'classes').resolve()
    if class_dir.parent != BUILD.resolve(): raise RuntimeError('Unexpected build path')
    if class_dir.exists(): shutil.rmtree(class_dir)
    for folder in ['classes', 'dex', 'res/drawable']:
        (BUILD / folder).mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT.parent / 'Resources/Icon.png', BUILD / 'res/drawable/icon.png')
    sources = sorted((ROOT / 'src').rglob('*.java'))
    run(JDK / 'bin/javac.exe', '-encoding', 'UTF-8', '-source', '7', '-target', '7',
        '-Xlint:-options', '-classpath', os.pathsep.join(str(p) for p in [API, JSON, *LIBS]),
        '-d', BUILD / 'classes', *sources)
    classes = BUILD / 'app.jar'
    with zipfile.ZipFile(classes, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted((BUILD / 'classes').rglob('*.class')):
            archive.write(path, path.relative_to(BUILD / 'classes').as_posix())
    run(JDK / 'bin/java.exe', '-Xmx2g', '-cp', TOOLS / 'lib/d8.jar',
        'com.android.tools.r8.R8', '--release', '--min-api', '9', '--no-desugaring',
        '--lib', API, '--lib', JSON, '--lib', JDK, '--pg-conf', ROOT / 'proguard-rules.pro',
        '--output', BUILD / 'dex', classes, *LIBS)
    run(TOOLS / 'aapt.exe', 'package', '-f', '-M', ROOT / 'AndroidManifest.xml',
        '-S', BUILD / 'res', '-A', ROOT / 'assets', '-I', SDK / 'platforms/android-34/android.jar',
        '-F', BUILD / 'unsigned.apk')
    with zipfile.ZipFile(BUILD / 'unsigned.apk', 'a', zipfile.ZIP_DEFLATED) as archive:
        dexes = sorted((BUILD / 'dex').glob('classes*.dex'))
        if len(dexes) != 1: raise RuntimeError('Android 2.3 requires one DEX file')
        archive.write(dexes[0], 'classes.dex')
    run(TOOLS / 'zipalign.exe', '-f', '4', BUILD / 'unsigned.apk', BUILD / 'aligned.apk')
    # Dedicated local test key, never committed. Retain it to allow APK updates.
    key = ROOT / '.signing/test.keystore'
    key.parent.mkdir(exist_ok=True)
    if not key.exists():
        run(JDK / 'bin/keytool.exe', '-genkeypair', '-keystore', key, '-storepass', 'android',
            '-keypass', 'android', '-alias', 'test', '-keyalg', 'RSA', '-keysize', '2048',
            '-validity', '10000', '-dname', 'CN=MangaLib Android Test')
    version = ET.parse(ROOT / 'AndroidManifest.xml').getroot().get('{http://schemas.android.com/apk/res/android}versionName')
    apk = BUILD / ('OldLib_' + version + '_Android_2.3.apk')
    signer = TOOLS / 'lib/apksigner.jar'
    run(JDK / 'bin/java.exe', '-jar', signer, 'sign', '--ks', key, '--ks-pass', 'pass:android',
        '--key-pass', 'pass:android', '--ks-key-alias', 'test', '--min-sdk-version', '9',
        '--v1-signing-enabled', 'true', '--v2-signing-enabled', 'true', '--out', apk, BUILD / 'aligned.apk')
    run(JDK / 'bin/java.exe', '-jar', signer, 'verify', '--verbose', '--min-sdk-version', '9', apk)
    run(TOOLS / 'aapt.exe', 'dump', 'badging', apk)
    print('APK:', apk, apk.stat().st_size, 'bytes')
