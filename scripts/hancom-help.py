#!/usr/bin/env python3
"""Fetches the 한컴오피스 2024 한/글 도움말 into build/hancom-help (not committed):
toc.md (the whole table of contents with each page's path), pages/*.txt (each page
as text, pictures as [img path]) and img/ (the pictures at those paths)."""
import concurrent.futures as cf, html, json, os, re, urllib.parse, urllib.request

BASE = "https://help.hancom.com/hoffice130/ko-KR/Hwp/"
OUT = os.path.join(os.path.dirname(__file__), "..", "build", "hancom-help")


def fetch(path):
    return urllib.request.urlopen(BASE + urllib.parse.quote(path)).read()


def toc(key="toc", depth=0):
    js = fetch(f"whxdata/{key}.new.js").decode()
    for node in json.loads(re.search(r"var toc\s*=\s*(\[.*\]);", js, re.S).group(1)):
        yield "  " * depth + f"- {node['name']}" + (f" ({node['url']})" if node.get("url") else "")
        if node["type"] == "book" and node.get("key"):
            yield from toc(node["key"], depth + 1)


def page(path):
    s = re.sub(r"(?s)<!--.*?-->", "", fetch(path).decode("utf-8", "replace"))
    s = re.sub(r"(?is)<(script|style|head).*?</\1>", "", s)
    pictures = []

    def picture(m):
        pictures.append(os.path.normpath(os.path.join(os.path.dirname(path), m.group(1))))
        return f"[img {pictures[-1]}]"

    s = re.sub(r'(?is)<img[^>]*?src="([^"]*)"[^>]*>', picture, s)
    s = re.sub(r"(?i)<(br|p|li|tr|h\d|div)[^>]*>", "\n", s)
    s = re.sub(r"(?i)<t[dh][^>]*>", " | ", s)
    s = html.unescape(re.sub(r"<[^>]+>", "", s))
    s = re.sub(r"\n\s*\n+", "\n", re.sub(r"[ \t\xa0]+", " ", s)).replace("www.hancom.com", "").strip()
    with open(os.path.join(OUT, "pages", path.replace("/", "__")[:-4] + ".txt"), "w") as f:
        f.write(f"# {path}\n{s}\n")
    return pictures


def picture(path):
    out = os.path.join(OUT, "img", path)
    if not os.path.exists(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "wb") as f:
            f.write(fetch(path))


if __name__ == "__main__":
    os.makedirs(os.path.join(OUT, "pages"), exist_ok=True)
    lines = list(toc())
    with open(os.path.join(OUT, "toc.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    paths = {l.rsplit(" (", 1)[1][:-1].split("#")[0] for l in lines if l.endswith(")") and ".htm" in l}
    with cf.ThreadPoolExecutor(6) as pool:
        pictures = set().union(*pool.map(page, sorted(paths)))
        list(pool.map(picture, sorted(p for p in pictures if "number_circle" not in p)))
    print(f"{len(lines)} entries, {len(paths)} pages, {len(pictures)} pictures in {os.path.normpath(OUT)}")
