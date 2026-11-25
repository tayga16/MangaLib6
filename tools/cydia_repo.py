"""Build and verify a flat, gzip-compatible Cydia repository (standard library only)."""
import argparse
import bz2
import gzip
import hashlib
import html
import io
import os
from pathlib import Path, PurePosixPath
import plistlib
import tarfile
from datetime import datetime, timezone
from email.utils import format_datetime
from urllib.parse import urlsplit
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EPOCH = int(os.environ.get('SOURCE_DATE_EPOCH', '1577836800'))


def digest(data, algorithm):
    return hashlib.new(algorithm, data).hexdigest()


def fields(text):
    result = {}
    key = None
    for line in text.splitlines():
        if line.startswith((' ', '\t')):
            if key is None:
                raise ValueError('Control continuation without a field')
            result[key] += '\n' + line
        elif line:
            key, value = line.split(':', 1)
            if key in result:
                raise ValueError('Duplicate control field: ' + key)
            result[key] = value.strip()
    return result


def deb_members(path):
    data = path.read_bytes()
    if data[:8] != b'!<arch>\n':
        raise ValueError('Not a Debian ar archive')
    offset = 8
    members = {}
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:] != b'`\n':
            raise ValueError('Invalid ar header')
        name = header[:16].decode('ascii').strip().rstrip('/')
        size = int(header[48:58])
        if size < 0 or offset + 60 + size > len(data) or name in members:
            raise ValueError('Invalid ar member: ' + name)
        members[name] = data[offset + 60:offset + 60 + size]
        offset += 60 + size + size % 2
    if offset != len(data) or list(members) != ['debian-binary', 'control.tar.gz', 'data.tar.gz']:
        raise ValueError('Legacy Cydia requires debian-binary, control.tar.gz, data.tar.gz in order')
    if members['debian-binary'] != b'2.0\n':
        raise ValueError('Unsupported Debian archive version')
    return members


def tar_files(data):
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        for entry in archive:
            name = str(PurePosixPath(entry.name))
            if name.startswith('/') or '..' in PurePosixPath(name).parts:
                raise ValueError('Unsafe archive path: ' + name)
            if entry.uid != 0 or entry.gid != 0 or entry.mode & 0o6000:
                raise ValueError('Invalid ownership or permissions: ' + name)
            if entry.isfile():
                if name in files:
                    raise ValueError('Duplicate tar member: ' + name)
                files[name] = (entry.mode, archive.extractfile(entry).read())
            elif not entry.isdir():
                raise ValueError('Unexpected tar member: ' + name)
    return files


def verify_deb(path, ipa=None):
    members = deb_members(path)
    control_files = tar_files(members['control.tar.gz'])
    data_files = tar_files(members['data.tar.gz'])
    control_text = control_files['control'][1].decode('utf-8').rstrip() + '\n'
    control = fields(control_text)
    info = plistlib.loads(data_files['Applications/MangaLib6.app/Info.plist'][1])
    assert control['Package'] == info['CFBundleIdentifier'] == 'ru.mangapad.apitest'
    assert control['Version'] == info['CFBundleShortVersionString']
    assert control['Architecture'] == 'iphoneos-arm'
    assert control['Depends'] == 'firmware (>= 5.1), uikittools'
    assert info['MinimumOSVersion'] == '5.1' and info['UIDeviceFamily'] == [1, 2]
    executable = data_files['Applications/MangaLib6.app/MangaLib6']
    assert executable[0] == 0o755 and executable[1][:4] == bytes.fromhex('cefaedfe')
    for script in ('postinst', 'postrm'):
        mode, body = control_files[script]
        assert mode == 0o755 and body.startswith(b'#!/bin/sh\n') and b'\r' not in body
        assert body == (ROOT / 'packaging' / script).read_bytes().replace(b'\r\n', b'\n')
    md5sums = control_files['md5sums'][1].decode('utf-8').splitlines()
    checked = set()
    for line in md5sums:
        checksum, name = line.split('  ', 1)
        name = str(PurePosixPath(name))
        assert digest(data_files[name][1], 'md5') == checksum
        checked.add(name)
    assert checked == set(data_files)
    if ipa:
        with zipfile.ZipFile(ipa) as archive:
            assert archive.testzip() is None
            ipa_files = {name.replace('Payload/', 'Applications/', 1): archive.read(name)
                         for name in archive.namelist() if not name.endswith('/')}
        assert set(ipa_files) == set(data_files)
        for name, (_, body) in data_files.items():
            assert ipa_files[name] == body, 'IPA/DEB mismatch: ' + name
    return control, control_text


def verify_repo(output):
    packages = (output / 'Packages').read_bytes()
    assert gzip.decompress((output / 'Packages.gz').read_bytes()) == packages
    assert bz2.decompress((output / 'Packages.bz2').read_bytes()) == packages
    for block in packages.decode('utf-8').strip().split('\n\n'):
        stanza = fields(block)
        filename = stanza['Filename']
        assert filename.startswith('debs/') and '..' not in PurePosixPath(filename).parts
        data = (output / filename).read_bytes()
        assert int(stanza['Size']) == len(data)
        for key, algorithm in [('MD5sum', 'md5'), ('SHA1', 'sha1'), ('SHA256', 'sha256')]:
            assert stanza[key] == digest(data, algorithm)
    release = fields((output / 'Release').read_text(encoding='utf-8'))
    for key, algorithm in [('MD5Sum', 'md5'), ('SHA1', 'sha1'), ('SHA256', 'sha256')]:
        entries = release[key].strip().splitlines()
        assert len(entries) == 3
        for line in entries:
            checksum, size, filename = line.split()
            assert filename in ('Packages', 'Packages.gz', 'Packages.bz2')
            data = (output / filename).read_bytes()
            assert int(size) == len(data) and checksum == digest(data, algorithm)
    for block in packages.decode('utf-8').strip().split('\n\n'):
        icon_name = PurePosixPath(urlsplit(fields(block)['Icon']).path).name
        assert icon_name in ('MangaLibIcon.png', 'CydiaIcon.png')
        assert (output / icon_name).read_bytes().startswith(b'\x89PNG\r\n\x1a\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deb', type=Path, required=True)
    parser.add_argument('--ipa', type=Path, help='Verify that IPA and DEB contain identical app files')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/cydia/repo')
    parser.add_argument('--url', default='http://tayga16.ru:8088/repo/')
    args = parser.parse_args()
    parsed = urlsplit(args.url)
    if parsed.scheme not in ('http', 'https') or not parsed.netloc or parsed.query or parsed.fragment:
        parser.error('--url must be an HTTP(S) repository directory URL')
    url = args.url.rstrip('/') + '/'
    control, control_text = verify_deb(args.deb, args.ipa)
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    (output / 'debs').mkdir(exist_ok=True)
    filename = args.deb.name
    body = args.deb.read_bytes()
    (output / 'debs' / filename).write_bytes(body)
    package_text = ''.join(line + '\n' for line in control_text.splitlines()
                           if not line.startswith(('Icon:', 'Depiction:')))
    package_text += (f'Icon: {url}MangaLibIcon.png\nDepiction: {url}depiction.html\n'
                     f'Filename: debs/{filename}\nSize: {len(body)}\n')
    for key, algorithm in [('MD5sum', 'md5'), ('SHA1', 'sha1'), ('SHA256', 'sha256')]:
        package_text += f'{key}: {digest(body, algorithm)}\n'
    packages = (package_text + '\n').encode('utf-8')
    (output / 'Packages').write_bytes(packages)
    (output / 'Packages.gz').write_bytes(gzip.compress(packages, mtime=EPOCH))
    (output / 'Packages.bz2').write_bytes(bz2.compress(packages))
    release = ('Origin: tayga16\nLabel: tayga16 MangaLib6\nSuite: stable\n'
               'Architectures: iphoneos-arm\nComponents: main\n'
               'Description: MangaLib6 for iPhone and iPad (iOS 5.1+)\n'
               f'Date: {format_datetime(datetime.fromtimestamp(EPOCH, timezone.utc), usegmt=True)}\n')
    for key, algorithm in [('MD5Sum', 'md5'), ('SHA1', 'sha1'), ('SHA256', 'sha256')]:
        release += key + ':\n'
        for name in ('Packages', 'Packages.gz', 'Packages.bz2'):
            data = (output / name).read_bytes()
            release += f' {digest(data, algorithm)} {len(data)} {name}\n'
    (output / 'Release').write_text(release, encoding='utf-8', newline='\n')
    (output / 'MangaLibIcon.png').write_bytes((ROOT / 'Resources/Icon.png').read_bytes())
    (output / 'CydiaIcon.png').unlink(missing_ok=True)
    page = (ROOT / 'packaging/index.html').read_text(encoding='utf-8')
    for key, value in {'VERSION': control['Version'], 'URL': url,
                       'DEB': 'debs/' + filename}.items():
        page = page.replace('{{' + key + '}}', html.escape(value, quote=True))
    (output / 'index.html').write_text(page, encoding='utf-8', newline='\n')
    for name in ('depiction.html', 'site tweaks.png'):
        (output / name).write_bytes((ROOT / 'packaging' / name).read_bytes())
    verify_repo(output)
    archive_path = output.parent / f'MangaLib6_{control["Version"]}_Cydia_repo.tar.gz'
    with archive_path.open('wb') as target:
        with gzip.GzipFile(fileobj=target, mode='wb', mtime=EPOCH, filename='') as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for file in sorted(output.rglob('*')):
                    if not file.is_file():
                        continue
                    data = file.read_bytes()
                    entry = tarfile.TarInfo('repo/' + file.relative_to(output).as_posix())
                    entry.size, entry.mode, entry.mtime = len(data), 0o644, EPOCH
                    archive.addfile(entry, io.BytesIO(data))
    print(f'PASS: DEB {control["Version"]}, legacy gzip, permissions, app files, all index checksums')
    print(f'Repository: {output.resolve()}')
    print(f'Deployment archive: {archive_path.resolve()}')


if __name__ == '__main__':
    main()
