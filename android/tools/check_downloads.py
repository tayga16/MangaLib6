"""Exercise persistent downloads without network or an emulator."""
from pathlib import Path
import os
import subprocess
ROOT = Path(__file__).resolve().parents[1]
JDK = Path(os.environ.get('JAVA_HOME', str(Path.home() / 'jdk-17/jdk-17.0.20.1+1')))
OUT = ROOT / 'build/download-check'
OUT.mkdir(parents=True, exist_ok=True)
JSON = ROOT / 'deps/json-20080701.jar'
subprocess.run([str(JDK / 'bin/javac.exe'), '-encoding', 'UTF-8', '-source', '7', '-target', '7',
    '-Xlint:-options', '-cp', str(JSON), '-d', str(OUT),
    str(ROOT / 'src/ru/mangapad/legacy/ChapterDownloads.java'), str(ROOT / 'tests/ChapterDownloadsCheck.java')], check=True)
subprocess.run([str(JDK / 'bin/java.exe'), '-cp', os.pathsep.join([str(OUT), str(JSON)]),
    'ru.mangapad.legacy.ChapterDownloadsCheck', str(OUT / 'files')], check=True, timeout=20)
