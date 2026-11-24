"""Launch only the dedicated test emulator, hidden, without a snapshot or SD card."""
from pathlib import Path
import subprocess

ROOT = Path.home() / 'MangaLib6-tools/android-emulator'
IMAGE = ROOT / 'gingerbread/android-2.3.3_r02-linux/images'
AVD = ROOT / 'test.avd'
AVD.mkdir(exist_ok=True)
(AVD / 'config.ini').write_text('''hw.cpu.arch=arm
hw.cpu.model=arm926
hw.ramSize=128
vm.heapSize=24
hw.lcd.width=320
hw.lcd.height=480
hw.lcd.density=160
hw.keyboard=yes
hw.gpu.enabled=no
disk.dataPartition.size=32M
''', encoding='ascii')
startup = subprocess.STARTUPINFO()
startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
startup.wShowWindow = 0
log = (ROOT / 'test-emulator.log').open('w')
args = [str(ROOT / 'classic/tools/emulator-arm.exe'), '-sysdir', str(IMAGE),
    '-system', str(IMAGE / 'system.img'), '-kernel', str(IMAGE / 'kernel-qemu'),
    '-ramdisk', str(IMAGE / 'ramdisk.img'), '-initdata', str(IMAGE / 'userdata.img'),
    '-datadir', str(AVD), '-data', str(AVD / 'userdata.img'),
    '-cache', str(AVD / 'cache.img'), '-partition-size', '32', '-memory', '128',
    '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot', '-no-skin',
    '-skin', '320x480', '-gpu', 'off', '-port', '5580']
process = subprocess.Popen(args, cwd=ROOT, startupinfo=startup,
    creationflags=subprocess.CREATE_NO_WINDOW, stdout=log, stderr=log)
(ROOT / 'test-emulator.pid').write_text(str(process.pid), encoding='ascii')
print('Emulator PID:', process.pid, 'ADB: emulator-5580')
