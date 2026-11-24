"""Verify the produced IPA's version, legacy ABI and download support."""
from pathlib import Path
import plistlib
import struct
import sys
import zipfile

path = Path(sys.argv[1])
with zipfile.ZipFile(path) as archive:
    assert archive.testzip() is None
    info = plistlib.loads(archive.read('Payload/MangaLib6.app/Info.plist'))
    executable = archive.read('Payload/MangaLib6.app/MangaLib6')
    assert executable[:4] == bytes.fromhex('cefaedfe')
    assert struct.unpack_from('<I', executable, 4)[0] == 12  # ARM
    assert info['MinimumOSVersion'] == '5.1'
    assert info['CFBundleShortVersionString'] == '0.5.1'
    assert info['CFBundleVersion'] == '16'
    assert info['UIDeviceFamily'] == [1, 2]
    for selector in [b'downloadNextPage', b'openDownloaded:page:', b'savePage:index:entry:', b'downloadCurrentChapter', b'setReaderFullscreen:']:
        assert selector in executable
    assert b'ProgressTestController' not in executable
    assert b'DownloadTestController' not in executable
    print('PASS: IPA 0.5.1, ARMv7, iOS 5.1+, iPhone/iPad, chapter downloads, no test code')
