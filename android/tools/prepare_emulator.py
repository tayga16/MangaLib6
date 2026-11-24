"""Download official Gingerbread SDK image and classic emulator into local tools."""
from pathlib import Path
import io
import urllib.request
import zipfile

DEST = Path.home() / 'MangaLib6-tools/android-emulator'
def fetch(url, output, select):
    # Keep archives in RAM; extract only the required emulator/image files.
    with urllib.request.urlopen(url, timeout=45) as source:
        archive = io.BytesIO(source.read())
    with zipfile.ZipFile(archive) as package:
        for item in package.infolist():
            if not item.is_dir() and select(item.filename):
                package.extract(item, output)
    print('Prepared', output, flush=True)

if __name__ == '__main__':
    DEST.mkdir(parents=True, exist_ok=True)
    if not (DEST / 'gingerbread/android-2.3.3_r02-linux/images/system.img').exists():
        fetch('https://dl.google.com/android/repository/android-2.3.3_r02-linux.zip',
            DEST / 'gingerbread', lambda name: '/images/' in name)
    if not (DEST / 'classic/tools/emulator-arm.exe').exists():
        fetch('https://dl.google.com/android/repository/tools_r22.6.2-windows.zip',
            DEST / 'classic', lambda name: name in ['tools/emulator.exe', 'tools/emulator-arm.exe']
            or name.endswith('.dll') and '/lib/' not in name)
