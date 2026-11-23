#!/usr/bin/env python3
"""Check that every link into a built book page resolves: the target file
exists and, when the link has a fragment, the target page has that id.

    book/check_anchors.py out/en out/ja

mdbook-linkcheck verifies that linked files exist but not fragments, and a
translated heading gets a new generated id, so a link that works in English can
break in Japanese. The headings that are link targets carry explicit ids.
"""
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlparse


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.links = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            self.ids.add(a["id"])
        if tag == "a" and "href" in a:
            self.links.append(a["href"])


def main(roots):
    bad = 0
    for root in map(Path, roots):
        pages = {}
        for f in root.rglob("*.html"):
            p = Page()
            p.feed(f.read_text(encoding="utf-8"))
            pages[f.resolve()] = p
        for f, p in pages.items():
            for href in p.links:
                u = urlparse(href)
                if u.scheme or u.netloc or not (u.path or u.fragment):
                    continue
                target = (f if not u.path else (f.parent / unquote(u.path))).resolve()
                if target.is_dir():
                    target = target / "index.html"
                if target not in pages:
                    print(f"{f.relative_to(root.resolve())}: missing file {href}")
                    bad += 1
                elif u.fragment and unquote(u.fragment) not in pages[target].ids:
                    print(f"{f.relative_to(root.resolve())}: missing anchor {href}")
                    bad += 1
    print(f"{bad} broken link(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
