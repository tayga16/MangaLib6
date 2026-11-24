"""Compare public MangaLib API responses without printing credentials."""
import concurrent.futures
import json
import urllib.error
import urllib.request

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1',
    'Site-Id': '1', 'Referer': 'https://mangalib.me/', 'Origin': 'https://mangalib.me',
    'Accept': 'application/json',
}
PATHS = [
    'https://api.cdnlibs.org/api/manga?site_id%5B%5D=1&q=chainsaw&per_page=20',
    'https://api.cdnlibs.org/api/constants?fields%5B%5D=imageServers',
    'https://api.lib.social/api/manga?site_id%5B%5D=1&q=chainsaw&per_page=20',
    'https://api.lib.social/api/constants?fields%5B%5D=imageServers',
]
def check(url):
    try:
        response = urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=20)
        body = response.read()
        value = json.loads(body).get('data')
        if isinstance(value, list):
            return url, response.status, len(body), len(value), [(v.get('slug_url'), v.get('name')) for v in value[:3]]
        return url, response.status, len(body), str(value)[:700]
    except urllib.error.HTTPError as error:
        return url, error.code, error.read(250).decode('utf-8', errors='replace')
    except Exception as error:
        return url, str(error)

for result in concurrent.futures.ThreadPoolExecutor(max_workers=4).map(check, PATHS):
    print(result, flush=True)
