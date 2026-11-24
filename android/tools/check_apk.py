"""Check the exact APK's legacy packaging and private crypto implementation."""
from pathlib import Path
import hashlib
import struct
import sys
import zipfile

apk = Path(sys.argv[1])
with zipfile.ZipFile(apk) as archive:
    assert [name for name in archive.namelist() if name.endswith('.dex')] == ['classes.dex']
    assert not any(name.startswith('ru/mangapad/legacy/TransportCheck') for name in archive.namelist())
    dex = archive.read('classes.dex')
    size, offset = struct.unpack_from('<II', dex, 56)
    strings = []
    for index in range(size):
        at = struct.unpack_from('<I', dex, offset + 4 * index)[0]
        while dex[at] & 128:
            at += 1
        at += 1
        strings.append(dex[at:dex.index(b'\x00', at)].decode('utf-8', errors='replace'))
    assert any('LegacyHttp$LegacyCrypto' in value for value in strings)
    assert not any(value.startswith('Lorg/bouncycastle/') for value in strings), 'System BC class collision'
    assert not any(any(name in value for name in ('TransportCheck', 'DeadlineCheck', 'PageBufferCheck',
        'ChapterDownloadsCheck', 'PageQualityCheck', 'PageDecoderCheck', 'DeviceNetworkCheck', 'ZoomDeviceCheck')) for value in strings), 'Test code in APK'
    assert 'https://api.cdnlibs.org/api' in strings
    assert 'https://api.lib.social/api' in strings
    assert any('Резервный API' in value for value in strings)
    assert any('RequestDeadline' in value for value in strings), 'Missing request deadlines'
    assert any('нет ответа за 30 секунд' in value for value in strings), 'Missing UI timeout'
    assert 'Отменить загрузку' in strings, 'Missing cancellation control'
    assert 'Не удалось загрузить' in strings, 'Missing visible error dialog'
    assert 'OldLib 0.1.0 · Тестовая версия · Android 2.3+' in strings, 'Wrong UI version'
    assert any('PageRegion' in value for value in strings), 'Missing source zoom decoder'
    assert any('PageSources' in value for value in strings), 'Missing encoded page cache'
    assert any('Connection: keep-alive' in value for value in strings), 'Missing persistent HTTPS'
    assert 'Полный экран' in strings, 'Missing fullscreen control'
    assert 'Загрузки' in strings and 'Скачать главу' in strings and 'Продолжить скачивание' in strings
    assert any('ChapterDownloads' in value for value in strings), 'Missing persistent chapters'
    assert any('Буфер: ' in value for value in strings) and any('Назад: ' in value for value in strings), 'Missing buffer counters'
    assert struct.unpack_from('<I', dex, 88)[0] < 65536
    print('PASS: single DEX, relocated BC, explicit crypto registration, no test classes')
    print('Methods:', struct.unpack_from('<I', dex, 88)[0])
    print('CA bundle bytes:', len(archive.read('assets/cacert.pem')))
print('SHA256:', hashlib.sha256(apk.read_bytes()).hexdigest())
