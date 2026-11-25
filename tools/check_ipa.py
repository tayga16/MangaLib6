"""Verify the produced IPA's version, legacy ABI and download support."""
from pathlib import Path
import plistlib
import struct
import sys
import zipfile

path = Path(sys.argv[1])
source_info = plistlib.loads((Path(__file__).resolve().parents[1] / 'Info.plist').read_bytes())
with zipfile.ZipFile(path) as archive:
    assert archive.testzip() is None
    info = plistlib.loads(archive.read('Payload/MangaLib6.app/Info.plist'))
    executable = archive.read('Payload/MangaLib6.app/MangaLib6')
    assert executable[:4] == bytes.fromhex('cefaedfe')
    assert struct.unpack_from('<I', executable, 4)[0] == 12  # ARM
    assert info['MinimumOSVersion'] == '5.1'
    assert info['CFBundleShortVersionString'] == source_info['CFBundleShortVersionString']
    assert info['CFBundleVersion'] == source_info['CFBundleVersion']
    assert info['UIDeviceFamily'] == [1, 2]
    expected_icons = {
        'Icon': 57, 'Icon@2x': 114, 'Icon-72': 72, 'Icon-72@2x': 144,
        'Icon-Small': 29, 'Icon-Small@2x': 58,
        'Icon-Small-50': 50, 'Icon-Small-50@2x': 100,
    }
    for key, legacy_key in [('CFBundleIcons', 'CFBundleIconFiles'),
                            ('CFBundleIcons~ipad', 'CFBundleIconFiles~ipad')]:
        primary_icon = info[key]['CFBundlePrimaryIcon']
        assert primary_icon['CFBundleIconFiles'] == info[legacy_key]
        for name in primary_icon['CFBundleIconFiles']:
            png = archive.read('Payload/MangaLib6.app/' + name + '.png')
            assert png[:8] == b'\x89PNG\r\n\x1a\n'
            assert struct.unpack_from('>II', png, 16) == (expected_icons[name],) * 2
    for selector in [b'downloadNextPage', b'openDownloaded:page:', b'savePage:index:entry:', b'downloadCurrentChapter', b'setReaderFullscreen:']:
        assert selector in executable
    assert b'ProgressTestController' not in executable
    assert b'DownloadTestController' not in executable
    print(f"PASS: IPA {info['CFBundleShortVersionString']}, ARMv7, iOS 5.1+, iPhone/iPad icons, chapter downloads, no test code")
