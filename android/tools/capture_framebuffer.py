"""Read the legacy ADB framebuffer (Android 2.3 has no screencap command)."""
import socket
import struct
import sys
from pathlib import Path
from PIL import Image

def read(connection, length):
    data = bytearray()
    while len(data) < length:
        part = connection.recv(length - len(data))
        if not part:
            raise RuntimeError('ADB closed framebuffer connection')
        data.extend(part)
    return bytes(data)

def request(connection, message):
    encoded = message.encode('ascii')
    connection.sendall(f'{len(encoded):04x}'.encode('ascii') + encoded)
    status = read(connection, 4)
    if status != b'OKAY':
        length = int(read(connection, 4), 16)
        raise RuntimeError(read(connection, length).decode())

if __name__ == '__main__':
    with socket.create_connection(('127.0.0.1', 5037), timeout=10) as connection:
        request(connection, 'host:transport:' + sys.argv[1])
        request(connection, 'framebuffer:')
        version, = struct.unpack('<I', read(connection, 4))
        if version != 1:
            raise RuntimeError(f'Unsupported framebuffer version {version}')
        bpp, size, width, height, ro, rl, bo, bl, go, gl, ao, al = struct.unpack('<12I', read(connection, 48))
        pixels = read(connection, size)
    channels = ((ro, rl), (go, gl), (bo, bl))
    rgb = bytearray()
    for offset in range(0, size, bpp // 8):
        pixel = int.from_bytes(pixels[offset:offset + bpp // 8], 'little')
        rgb.extend(((pixel >> start) & ((1 << length) - 1)) * 255 // ((1 << length) - 1)
            for start, length in channels)
    target = Path(sys.argv[2])
    Image.frombytes('RGB', (width, height), bytes(rgb)).save(target)
    print(f'Framebuffer: {width}x{height}, {target}')
