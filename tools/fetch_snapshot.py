import argparse
import asyncio
import io
import json
import plistlib
from datetime import datetime, timezone
from pathlib import Path

from mangalib import Catalog, MangaLib
from PIL import Image


def plist_value(value):
    if isinstance(value, dict):
        return {key: plist_value(item) for key, item in value.items() if item is not None}
    if isinstance(value, list):
        return [plist_value(item) for item in value if item is not None]
    return value


async def fetch_snapshot(query: str, title: str, page_limit: int, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    cache = output.parent / ".snapshot-cache"
    async with Catalog(cache_dir=cache / "catalog") as catalog:
        results = await catalog.list_titles(query=query, refresh=True)
        titles = [item.model_dump(mode="json") for item in results.items]
        print(f"Catalog: {len(titles)} results for {query!r}", flush=True)

    async with MangaLib(title, cache_dir=cache / "title") as lib:
        info = await lib.get_info(refresh=True)
        volumes = await lib.get_table_of_contents(refresh=True)
        toc = [chapter for volume in volumes for chapter in volume.chapters]
        if not toc:
            raise RuntimeError("The title has no chapters")
        selected = None
        for candidate in toc[:10]:
            translations = await lib.get_translations(
                volume=candidate.volume, number=candidate.number
            )
            selected = next((branch for branch in translations if branch.is_open), None)
            if selected is not None:
                selected_chapter = candidate
                break
        if selected is None:
            raise RuntimeError("No publicly readable translation in the first ten chapters")
        chapter = await lib.get_chapter(
            volume=selected_chapter.volume,
            number=selected_chapter.number,
            branch_id=selected.branch_id,
            refresh=True,
        )
        print(
            f"Title: {info.name}; chapter {chapter.volume}-{chapter.number}; "
            f"{len(chapter.pages)} pages; branch {selected.branch_id}",
            flush=True,
        )
        sample_pages = chapter.pages[:page_limit]
        image_files = {}
        for position, page in enumerate(sample_pages, start=1):
            image_bytes = await lib.download_page(page)
            with Image.open(io.BytesIO(image_bytes)) as image:
                image = image.convert("RGB")
                image.thumbnail((1536, 2048))
                filename = f"page-{position:03d}.jpg"
                image.save(output / filename, "JPEG", quality=85)
            image_files[page.url] = filename
            print(f"Page {position}: {len(image_bytes)} bytes -> {filename}", flush=True)
        chapter_data = chapter.model_dump(mode="json", by_alias=True)
        chapter_data["pages"] = [
            page.model_dump(mode="json", by_alias=True) for page in sample_pages
        ]
        info_data = info.model_dump(mode="json")
        title_item = next(
            (item for item in titles if item.get("slug_url") == info_data["slug_url"]),
            info_data,
        )
        snapshot = {
            "captured_at": datetime.now(timezone.utc).isoformat(),
            "query": query,
            "title": title_item,
            "catalog": titles,
            "chapters": [selected_chapter.model_dump(mode="json", by_alias=True)],
            "chapter": chapter_data,
            "total_chapters": len(toc),
            "total_pages": len(chapter.pages),
            "image_files": image_files,
        }
        (output / "snapshot.json").write_text(
            json.dumps(snapshot, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        (output / "snapshot.plist").write_bytes(plistlib.dumps(plist_value(snapshot)))
        print(f"Saved live API snapshot to {output / 'snapshot.json'}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Check the SDK against the live MangaLib API")
    parser.add_argument("--query", default="chainsaw")
    parser.add_argument("--title", default="https://mangalib.me/ru/manga/7965--chainsaw-man")
    parser.add_argument("--pages", type=int, default=3)
    parser.add_argument(
        "--output", type=Path, default=Path(__file__).resolve().parents[1] / "Resources"
    )
    arguments = parser.parse_args()
    if not 1 <= arguments.pages <= 20:
        parser.error("--pages must be between 1 and 20")
    asyncio.run(fetch_snapshot(arguments.query, arguments.title, arguments.pages, arguments.output))


if __name__ == "__main__":
    main()
