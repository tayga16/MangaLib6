"""Build isolated R8 reader instrumentation under the installed app's heap.

Uses the reader sources in a separate package, with reflection names kept only
in this diagnostic DEX. Does not add hooks or keep rules to the delivered APK.
"""
from pathlib import Path
import os
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/zoom-device-check'
JDK = Path(os.environ.get('JAVA_HOME', str(Path.home() / 'jdk-17/jdk-17.0.20.1+1')))
SDK = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'AppData/Local/Android/Sdk')))
TOOLS = SDK / 'build-tools/34.0.0'
API = ROOT / 'deps/android-2.3.3.jar'
(OUT / 'classes').mkdir(parents=True, exist_ok=True)
(OUT / 'sources').mkdir(parents=True, exist_ok=True)
sources = [ROOT / 'tests/ZoomDeviceCheck.java'] + [
    ROOT / 'src/ru/mangapad/legacy' / (name + '.java') for name in
    ['PageView', 'PageRegion', 'PageResolution', 'PageDecoder']]
isolated = []
for source in sources:
    target = OUT / 'sources' / source.name
    target.write_text(source.read_text(encoding='utf-8').replace(
        'package ru.mangapad.legacy;', 'package ru.mangapad.legacy.zoomcheck;'), encoding='utf-8')
    isolated.append(target)
def run(*args): subprocess.run(list(map(str, args)), check=True)
run(JDK / 'bin/javac.exe', '-encoding', 'UTF-8', '-source', '7', '-target', '7',
    '-Xlint:-options', '-cp', API, '-d', OUT / 'classes', *isolated)
with zipfile.ZipFile(OUT / 'input.jar', 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted((OUT / 'classes').rglob('*.class')):
        archive.write(path, path.relative_to(OUT / 'classes').as_posix())
(OUT / 'rules.pro').write_text('''
-keep public class ru.mangapad.legacy.zoomcheck.ZoomDeviceCheck { public *; }
-keepclassmembers class ru.mangapad.legacy.zoomcheck.PageView {
    private *** detail;
    private *** detailTask;
    private void scaleAt(float,float,float);
}
-keep class ru.mangapad.legacy.zoomcheck.PageRegion { *; }
-dontwarn javax.microedition.khronos.**
-dontwarn org.xmlpull.v1.**
''', encoding='utf-8')
run(JDK / 'bin/java.exe', '-cp', TOOLS / 'lib/d8.jar', 'com.android.tools.r8.R8',
    '--release', '--min-api', '9', '--no-desugaring', '--lib', API, '--lib', JDK,
    '--pg-conf', OUT / 'rules.pro', '--output', OUT / 'checks.zip', OUT / 'input.jar')
(OUT / 'AndroidManifest.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="ru.mangapad.legacy.zoomcheck">
<uses-sdk android:minSdkVersion="10" android:targetSdkVersion="10" />
<application android:label="MangaLib zoom check" />
<instrumentation android:name="ru.mangapad.legacy.zoomcheck.ZoomDeviceCheck" android:targetPackage="ru.mangapad.legacy" />
</manifest>
''', encoding='utf-8')
run(TOOLS / 'aapt.exe', 'package', '-f', '-M', OUT / 'AndroidManifest.xml', '-I', API, '-F', OUT / 'unsigned.apk')
with zipfile.ZipFile(OUT / 'unsigned.apk', 'a', zipfile.ZIP_DEFLATED) as archive:
    with zipfile.ZipFile(OUT / 'checks.zip') as dex:
        archive.writestr('classes.dex', dex.read('classes.dex'))
run(JDK / 'bin/java.exe', '-jar', TOOLS / 'lib/apksigner.jar', 'sign',
    '--ks', ROOT / '.signing/test.keystore', '--ks-pass', 'pass:android', '--ks-key-alias', 'test',
    '--min-sdk-version', '10', '--out', OUT / 'zoom-check.apk', OUT / 'unsigned.apk')
print(OUT / 'zoom-check.apk')
