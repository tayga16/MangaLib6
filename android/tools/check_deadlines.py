"""Regress UI cancellation with a socket that blocks while closing."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
JDK = Path(os.environ.get('JAVA_HOME', str(Path.home() / 'jdk-17/jdk-17.0.20.1+1')))
OUT = ROOT / 'build/deadline-check'
OUT.mkdir(parents=True, exist_ok=True)
subprocess.run([str(JDK / 'bin/javac.exe'), '-encoding', 'UTF-8', '-source', '7', '-target', '7',
    '-Xlint:-options', '-d', str(OUT), str(ROOT / 'src/ru/mangapad/legacy/RequestDeadline.java'),
    str(ROOT / 'tests/DeadlineCheck.java')], check=True)
subprocess.run([str(JDK / 'bin/java.exe'), '-cp', str(OUT), 'ru.mangapad.legacy.DeadlineCheck'],
    check=True, timeout=10)
