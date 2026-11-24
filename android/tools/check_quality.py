"""Check source quality and bounded disk/memory budgets without an emulator."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
JDK = Path(os.environ.get('JAVA_HOME', str(Path.home() / 'jdk-17/jdk-17.0.20.1+1')))
OUT = ROOT / 'build/quality-check'
OUT.mkdir(parents=True, exist_ok=True)
subprocess.run([str(JDK / 'bin/javac.exe'), '-encoding', 'UTF-8', '-source', '7', '-target', '7',
    '-Xlint:-options', '-d', str(OUT), str(ROOT / 'src/ru/mangapad/legacy/PageResolution.java'),
    str(ROOT / 'src/ru/mangapad/legacy/PageSources.java'), str(ROOT / 'src/ru/mangapad/legacy/PageDecoder.java'),
    str(ROOT / 'tests/PageQualityCheck.java'), str(ROOT / 'tests/PageDecoderCheck.java')], check=True)
with tempfile.TemporaryDirectory(prefix='source-cache-', dir=OUT) as temporary:
    subprocess.run([str(JDK / 'bin/java.exe'), '-cp', str(OUT), 'ru.mangapad.legacy.PageQualityCheck',
        str(Path(temporary) / 'originals')], check=True, timeout=10)
subprocess.run([str(JDK / 'bin/java.exe'), '-cp', str(OUT), 'ru.mangapad.legacy.PageDecoderCheck'],
    check=True, timeout=10)
