import argparse
from pathlib import Path

from PIL import Image


ICON_SIZES = {
    "Icon.png": 57,
    "Icon@2x.png": 114,
    "Icon-72.png": 72,
    "Icon-72@2x.png": 144,
    "Icon-Small.png": 29,
    "Icon-Small@2x.png": 58,
    "Icon-Small-50.png": 50,
    "Icon-Small-50@2x.png": 100,
}


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Prepare MangaLib icons for the native iOS 5/6 gloss")
    parser.add_argument("--source", type=Path, default=root / "tools/artwork/mangalib-original.jpg")
    parser.add_argument("--output", type=Path, default=root / "Resources")
    arguments = parser.parse_args()
    with Image.open(arguments.source) as source:
        if source.width != source.height:
            parser.error("The source icon must be square")
        image = source.convert("RGB")
    arguments.output.mkdir(parents=True, exist_ok=True)
    for filename, size in ICON_SIZES.items():
        output = arguments.output / filename
        image.resize((size, size), Image.Resampling.LANCZOS).save(output, "PNG", optimize=True)
        print(f"{output}: {size}x{size}")


if __name__ == "__main__":
    main()
