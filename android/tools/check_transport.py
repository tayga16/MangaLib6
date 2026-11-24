from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
JDK = Path(os.environ.get('JAVA_HOME', str(Path.home() / 'jdk-17/jdk-17.0.20.1+1')))
LIBS = sorted((ROOT / 'deps').glob('bc*-1.83.jar'))
CP = os.pathsep.join(str(p) for p in [ROOT / 'build/classes', ROOT / 'deps/json-20080701.jar', *LIBS])
subprocess.run([str(JDK / 'bin/javac.exe'), '-encoding', 'UTF-8', '-cp', CP,
    '-d', str(ROOT / 'build/classes'), str(ROOT / 'tests/TransportCheck.java')], check=True)
subprocess.run([str(JDK / 'bin/java.exe'), '-cp', CP, 'ru.mangapad.legacy.TransportCheck',
    str(ROOT / 'assets/cacert.pem'), str(ROOT / 'build/test-page.jpg')], check=True)
