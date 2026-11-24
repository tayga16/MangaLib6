"""Compare public API access with ordinary headers and per-host cookies."""
import concurrent.futures
import http.cookiejar
import urllib.error
import urllib.request

PATH = '/api/manga?site_id%5B%5D=1&q=naruto&per_page=1'
BASES = ['https://api.cdnlibs.org', 'https://api.lib.social']
AGENTS = [
    ('legacy', 'Mozilla/5.0 (Linux; Android 2.3.3) MangaLib6/0.1.2'),
    ('browser', 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36'),
]

def probe(case):
    base, label, agent, site_headers = case
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    headers = {'User-Agent': agent, 'Accept': 'application/json'}
    if site_headers:
        headers.update({'Site-Id': '1', 'Referer': 'https://mangalib.me/', 'Origin': 'https://mangalib.me'})
    attempts = []
    for attempt in range(2):
        try:
            response = opener.open(urllib.request.Request(base + PATH, headers=headers), timeout=12)
        except urllib.error.HTTPError as error:
            response = error
        except Exception as error:
            attempts.append(str(error))
            break
        with response:
            body = response.read(500)
            attempts.append({'status': response.code, 'server': response.headers.get('Server'),
                'type': response.headers.get('Content-Type'), 'body': body.decode('utf-8', errors='replace')[:100],
                'cookie_names': [cookie.name for cookie in jar]})
        if response.code == 200:
            break
    return base, label, site_headers, attempts

cases = [(base, label, agent, site_headers) for base in BASES
    for label, agent in AGENTS for site_headers in [True, False]]
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    for result in pool.map(probe, cases):
        print(result, flush=True)
