import argparse
import plistlib
import zipfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Create a separate IPA with launch-time smoke checks")
    parser.add_argument("ipa", type=Path)
    arguments = parser.parse_args()
    output = arguments.ipa.with_name(arguments.ipa.stem + "-smoke.ipa")
    with zipfile.ZipFile(arguments.ipa) as source, zipfile.ZipFile(output, "w") as target:
        for entry in source.infolist():
            data = source.read(entry.filename)
            if entry.filename.endswith(".app/Info.plist"):
                info = plistlib.loads(data)
                info["MangaLib6SmokeTest"] = True
                data = plistlib.dumps(info)
            target.writestr(entry, data)
    print(output)


if __name__ == "__main__":
    main()
