#!/usr/bin/env python3
"""Lightweight retrieval-augmented generation, exposed over MCP.

This is deliberately small. It exists so a local model can look things up on the
web and in a folder of documents without pulling in a vector database, an
embedding model, or a framework.

How it stays light:
  * search is DuckDuckGo's HTML endpoint, so there is no API key and no second
    service to run;
  * ranking is BM25 over text chunks — about thirty lines of arithmetic — so
    there are no embeddings and no torch;
  * every dependency beyond the MCP protocol itself is in the standard library.

What that costs: BM25 is lexical, so it matches words rather than meaning. Ask
for "how do I stop a process" and a page that says "terminate a job" will rank
poorly. For a 9B model on a consumer GPU that trade is worth it — embeddings
would add a second model competing for the same 8 GB of VRAM.

The tools are served over MCP. The default transport is **stdio**, because that
is the only one llama.cpp's server speaks: it spawns this file as a child
process, reads JSON-RPC on its stdin and writes replies on its stdout, and stops
it again afterwards. Nothing has to be started or kept alive outside the model
server. `--http` switches to Streamable HTTP for clients that want a URL, such as
Open WebUI or OpenCode.

Run it with `rag on`, which attaches it to the model by adding it to
`~/llm/config.env` rather than starting anything.
"""

from __future__ import annotations

import ipaddress
import json
import math
import os
import re
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from pathlib import Path

# --------------------------------------------------------------------- config --
HOST = os.environ.get("RAG_HOST", "127.0.0.1")
PORT = int(os.environ.get("RAG_PORT", "8082"))
DOCS_DIR = Path(os.environ.get("RAG_DOCS", str(Path.home() / "rag" / "docs")))
USER_AGENT = os.environ.get(
    "RAG_USER_AGENT",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/122.0 Safari/537.36",
)
FETCH_TIMEOUT = float(os.environ.get("RAG_FETCH_TIMEOUT", "15"))
MAX_RESULTS = int(os.environ.get("RAG_MAX_RESULTS", "8"))
CHUNK_SIZE = int(os.environ.get("RAG_CHUNK_SIZE", "900"))
CHUNK_OVERLAP = int(os.environ.get("RAG_CHUNK_OVERLAP", "200"))

DDG_ENDPOINT = "https://html.duckduckgo.com/html/"


# ----------------------------------------------------------------------- http --
def _http(url: str, data: bytes | None = None, timeout: float | None = None,
          attempts: int = 2) -> str:
    """Fetch a URL and return it as text. Raises on network or HTTP failure.

    Retries once on a transient failure. Search results routinely point at hosts
    that rate-limit or briefly return 503 to a non-browser client, and a single
    retry turns many of those into successes. A 404 is not retried — it will not
    improve.
    """
    import time

    last: Exception | None = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(
                url,
                data=data,
                headers={
                    "User-Agent": USER_AGENT,
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    "Accept-Language": "en-US,en;q=0.9",
                },
            )
            with urllib.request.urlopen(req, timeout=timeout or FETCH_TIMEOUT) as resp:
                raw = resp.read(4_000_000)  # 4 MB ceiling; a page bigger than this is not prose
                charset = resp.headers.get_content_charset() or "utf-8"
            return raw.decode(charset, errors="replace")
        except urllib.error.HTTPError as e:
            last = e
            transient = e.code in (429, 500, 502, 503, 504)
        except urllib.error.URLError as e:
            last = e
            transient = True
        if not transient or attempt + 1 >= attempts:
            raise last
        time.sleep(0.6 * (attempt + 1))
    raise last  # unreachable, but keeps the type checker honest


def _is_fetchable(url: str) -> tuple[bool, str]:
    """Refuse schemes and addresses a local tool has no business reaching.

    The model chooses these URLs, and it can be talked into fetching something by
    a page it has already read. Loopback and link-local addresses are where
    credential endpoints and cloud metadata live, so they are blocked. The open
    internet and the local document folder are the intended targets.
    """
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return False, f"only http and https are fetchable, not '{parsed.scheme}'"
    host = parsed.hostname
    if not host:
        return False, "no host in URL"
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False, f"cannot resolve '{host}'"
    for info in infos:
        try:
            ip = ipaddress.ip_address(info[4][0])
        except ValueError:
            continue
        if ip.is_loopback or ip.is_link_local:
            return False, f"refusing to fetch {ip} (loopback or link-local)"
    return True, ""


# ------------------------------------------------------------------ ddg search --
class _DuckDuckGoParser(HTMLParser):
    """Pull titles, URLs and snippets out of DuckDuckGo's no-JavaScript page.

    The markup is a table of result blocks, each with an anchor carrying
    class="result__a" and a following node with class="result__snippet".
    Snippets are attached to the most recently seen result, because the snippet
    node is not nested inside the anchor.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.results: list[dict[str, str]] = []
        self._capture: str | None = None
        self._buf: list[str] = []
        self._href: str | None = None

    @staticmethod
    def _unwrap(href: str) -> str:
        # DDG wraps outbound links as //duckduckgo.com/l/?uddg=<encoded>
        if "uddg=" in href:
            query = urllib.parse.urlparse(href).query
            target = urllib.parse.parse_qs(query).get("uddg", [""])[0]
            if target:
                return target
        if href.startswith("//"):
            return "https:" + href
        return href

    def handle_starttag(self, tag, attrs):
        attrs_d = dict(attrs)
        classes = attrs_d.get("class", "") or ""
        if tag == "a" and "result__a" in classes:
            self._href = self._unwrap(attrs_d.get("href", ""))
            self._capture = "title"
            self._buf = []
        elif "result__snippet" in classes:
            self._capture = "snippet"
            self._buf = []

    def handle_data(self, data):
        if self._capture:
            self._buf.append(data)

    def handle_endtag(self, tag):
        if self._capture == "title" and tag == "a":
            title = " ".join("".join(self._buf).split())
            if self._href:
                self.results.append({"title": title, "url": self._href, "snippet": ""})
            self._capture = None
            self._href = None
        elif self._capture == "snippet" and tag in ("a", "div", "span"):
            snippet = " ".join("".join(self._buf).split())
            if self.results and not self.results[-1]["snippet"]:
                self.results[-1]["snippet"] = snippet
            self._capture = None


def ddg_search(query: str, num_results: int = 5) -> list[dict[str, str]]:
    body = urllib.parse.urlencode({"q": query, "kl": "us-en"}).encode()
    html = _http(DDG_ENDPOINT, data=body)
    parser = _DuckDuckGoParser()
    parser.feed(html)
    out: list[dict[str, str]] = []
    seen: set[str] = set()
    for r in parser.results:
        if not r["url"] or r["url"] in seen:
            continue
        seen.add(r["url"])
        out.append(r)
        if len(out) >= num_results:
            break
    return out


# --------------------------------------------------------------- text extraction --
_SKIP_TAGS = {"script", "style", "noscript", "svg", "nav", "header", "footer",
              "aside", "form", "iframe", "template", "button", "select"}
_BLOCK_TAGS = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
               "section", "article", "blockquote", "pre", "td"}


class _TextExtractor(HTMLParser):
    """Turn a page into readable prose.

    Not a full readability implementation — it drops the elements that never hold
    article text and turns block boundaries into newlines. That is enough to make
    BM25 rank passages rather than markup, which is the only thing this needs.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in _SKIP_TAGS:
            self._skip_depth += 1
        elif tag in _BLOCK_TAGS and not self._skip_depth:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in _SKIP_TAGS and self._skip_depth:
            self._skip_depth -= 1
        elif tag in _BLOCK_TAGS and not self._skip_depth:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self._skip_depth:
            self.parts.append(data)


def extract_text(html: str) -> str:
    parser = _TextExtractor()
    parser.feed(html)
    text = "".join(parser.parts)
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    text = re.sub(r"\n\s*\n\s*\n+", "\n\n", text)
    return text.strip()


# ------------------------------------------------------------------------- bm25 --
def tokenize(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", text.lower())


def chunk_text(text: str, size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[str]:
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return []
    if len(text) <= size:
        return [text]
    chunks, start = [], 0
    step = max(1, size - overlap)
    while start < len(text):
        chunks.append(text[start:start + size])
        start += step
    return chunks


def bm25_rank(query: str, chunks: list[str], top_k: int = 5,
              k1: float = 1.5, b: float = 0.75) -> list[tuple[float, int]]:
    """Rank chunks against a query. Returns (score, index), best first."""
    q_terms = tokenize(query)
    if not q_terms or not chunks:
        return []
    docs = [tokenize(c) for c in chunks]
    n = len(docs)
    avgdl = (sum(len(d) for d in docs) / n) if n else 1.0

    df: Counter[str] = Counter()
    for d in docs:
        df.update(set(d))

    scored: list[tuple[float, int]] = []
    for i, doc in enumerate(docs):
        if not doc:
            continue
        tf = Counter(doc)
        dl = len(doc)
        score = 0.0
        for term in q_terms:
            if term not in tf:
                continue
            idf = math.log(1 + (n - df[term] + 0.5) / (df[term] + 0.5))
            score += idf * (tf[term] * (k1 + 1)) / (
                tf[term] + k1 * (1 - b + b * dl / avgdl)
            )
        scored.append((score, i))
    scored.sort(key=lambda pair: (-pair[0], pair[1]))
    return scored[:top_k]


# --------------------------------------------------------------------- fetching --
def fetch_and_extract(url: str, max_chars: int = 8000) -> tuple[str, str]:
    """Fetch one page. Returns (text, error). Never raises."""
    ok, why = _is_fetchable(url)
    if not ok:
        return "", why
    try:
        html = _http(url)
    except urllib.error.HTTPError as e:
        return "", f"HTTP {e.code}"
    except urllib.error.URLError as e:
        return "", f"network error: {e.reason}"
    except Exception as e:  # noqa: BLE001 - a bad page must not take down the tool
        return "", f"{type(e).__name__}: {e}"
    text = extract_text(html)
    if not text:
        return "", "no readable text"
    return text[:max_chars], ""


def _gather(query: str, num_results: int, max_chars: int) -> tuple[list[dict], list[dict]]:
    """Search, then fetch the hits concurrently. Returns (sources, errors)."""
    hits = ddg_search(query, num_results=num_results)
    if not hits:
        return [], []

    def one(hit: dict) -> tuple[dict, str]:
        text, err = fetch_and_extract(hit["url"], max_chars=max_chars)
        return hit, (text if not err else "")

    with ThreadPoolExecutor(max_workers=min(6, len(hits))) as pool:
        fetched = list(pool.map(one, hits))

    sources, errors = [], []
    for hit, text in fetched:
        entry = {**hit, "text": text}
        sources.append(entry)
        if not text:
            errors.append({"title": hit["title"], "url": hit["url"]})
    return sources, errors


# ------------------------------------------------------------------------- mcp --
from mcp.server.mcpserver import MCPServer  # noqa: E402 - import after docstring

server = MCPServer(
    name="rag",
    version="1.0.0",
    instructions=(
        "Retrieval over the live web and a local document folder. Prefer "
        "`research` for questions about current events or anything you are "
        "unsure of: it searches, reads the top pages and returns the passages "
        "that best match, in one call. Cite the sources it returns."
    ),
)


@server.tool()
def web_search(query: str, num_results: int = 5) -> str:
    """Search the web and return result titles, URLs and snippets.

    Use this when you only need to find pages. To actually read them, follow up
    with `fetch_page`, or use `research` to do both at once.

    Args:
        query: What to search for.
        num_results: How many results to return (1-8).
    """
    n = max(1, min(int(num_results), MAX_RESULTS))
    try:
        hits = ddg_search(query, num_results=n)
    except Exception as e:  # noqa: BLE001
        return json.dumps({"error": f"search failed: {e}"}, indent=2)
    if not hits:
        return json.dumps({"query": query, "results": [],
                           "note": "no results; the endpoint may be rate-limiting"}, indent=2)
    return json.dumps({"query": query, "results": hits}, indent=2)


@server.tool()
def fetch_page(url: str, max_chars: int = 8000) -> str:
    """Fetch one URL and return its main text, with markup removed.

    Args:
        url: The page to read. Must be http or https.
        max_chars: Truncate the result to this many characters.
    """
    text, err = fetch_and_extract(url, max_chars=max(500, min(int(max_chars), 40000)))
    if err:
        return json.dumps({"url": url, "error": err}, indent=2)
    return json.dumps({"url": url, "text": text}, indent=2)


@server.tool()
def research(query: str, num_results: int = 4, max_chars: int = 12000) -> str:
    """Search the web, read the top pages, and return the best-matching passages.

    This is the tool to reach for first. It does the whole retrieval loop —
    search, fetch, chunk, rank — in a single call so you do not have to decide
    which page is worth reading. Passages are labelled with the source they came
    from, so cite them.

    Args:
        query: The question to research.
        num_results: How many pages to read (1-6).
        max_chars: Total character budget for the returned passages.
    """
    n = max(1, min(int(num_results), 6))
    try:
        sources, errors = _gather(query, n, max_chars=200_000)
    except Exception as e:  # noqa: BLE001
        return json.dumps({"error": f"research failed: {e}"}, indent=2)

    live = [s for s in sources if s["text"]]
    if not live:
        return json.dumps({
            "query": query,
            "error": "no pages could be read",
            "tried": errors,
        }, indent=2)

    # Rank every page's chunks against the query together, so a short highly
    # relevant page beats a long marginal one.
    chunks: list[str] = []
    owners: list[dict] = []
    for src in live:
        for c in chunk_text(src["text"]):
            chunks.append(c)
            owners.append(src)

    ranked = bm25_rank(query, chunks, top_k=6)

    passages, used = [], []
    budget = max(1000, int(max_chars))
    for score, idx in ranked:
        if score <= 0:
            continue
        src = owners[idx]
        passages.append({
            "source": src["title"],
            "url": src["url"],
            "passage": chunks[idx],
        })
        if src["url"] not in [u["url"] for u in used]:
            used.append({"title": src["title"], "url": src["url"]})
        budget -= len(chunks[idx])
        if budget <= 0:
            break

    if not passages:  # nothing matched lexically; hand over the openings instead
        for src in live[:2]:
            passages.append({"source": src["title"], "url": src["url"],
                             "passage": src["text"][:2000]})
            used.append({"title": src["title"], "url": src["url"]})

    return json.dumps({
        "query": query,
        "sources": used,
        "passages": passages,
        "pages_read": len(live),
        "pages_failed": errors,
    }, indent=2)


@server.tool()
def search_docs(query: str, k: int = 5) -> str:
    """Search local documents in the RAG docs folder using BM25 ranking.

    Use this for questions about the user's own files. It is lexical, not
    semantic, so exact wording matters.

    Args:
        query: What to look for.
        k: How many passages to return.
    """
    if not DOCS_DIR.is_dir():
        return json.dumps({"query": query, "results": [],
                           "note": f"no document folder at {DOCS_DIR}"}, indent=2)

    chunks: list[str] = []
    owners: list[str] = []
    for path in sorted(DOCS_DIR.rglob("*")):
        if not path.is_file() or path.stat().st_size > 2_000_000:
            continue
        if path.suffix.lower() not in {".txt", ".md", ".markdown", ".rst", ".org", ".csv", ".json", ".log"}:
            continue
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        for c in chunk_text(text):
            chunks.append(c)
            owners.append(str(path.relative_to(DOCS_DIR)))

    if not chunks:
        return json.dumps({"query": query, "results": [],
                           "note": f"no readable documents in {DOCS_DIR}"}, indent=2)

    ranked = bm25_rank(query, chunks, top_k=max(1, min(int(k), 20)))
    results = [
        {"file": owners[i], "score": round(s, 3), "passage": chunks[i]}
        for s, i in ranked if s > 0
    ]
    return json.dumps({"query": query, "results": results,
                       "chunks_searched": len(chunks)}, indent=2)


# ----------------------------------------------------------------------- main --
def _self_test() -> int:
    """Exercise retrieval without a client. Used by `rag test` and the installer."""
    print("  docs folder:", DOCS_DIR, "(exists)" if DOCS_DIR.is_dir() else "(missing)")
    print("  testing DuckDuckGo search ...", end="", flush=True)
    try:
        hits = ddg_search("llama.cpp server", num_results=3)
    except Exception as e:  # noqa: BLE001
        print(f" FAILED: {e}")
        return 1
    if not hits:
        print(" FAILED: no results (rate-limited?)")
        return 1
    print(f" {len(hits)} results")
    for h in hits:
        print(f"    - {h['title'][:64]}")
        print(f"      {h['url'][:96]}")

    print("  testing page fetch + extraction ...", end="", flush=True)
    text, err = fetch_and_extract(hits[0]["url"], max_chars=500)
    if err:
        print(f" FAILED: {err}")
        return 1
    print(f" {len(text)} chars")
    print(f"    {text[:120]!r}")

    print("  testing BM25 ranking ...", end="", flush=True)
    ranked = bm25_rank("process cpu usage", chunk_text(
        "The cat sat on the mat. " * 40 + "Measure process cpu usage with top. " * 5))
    print(f" top chunk index {ranked[0][1] if ranked else 'none'}"
          f" score {round(ranked[0][0], 2) if ranked else 0}")

    print("  testing the loopback guard ...", end="", flush=True)
    bad, why = _is_fetchable("http://127.0.0.1:11434/api/ps")
    print(f" {'correctly refused' if not bad else 'NOT REFUSED'}: {why}")
    return 0 if not bad else 1


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("--self-test", "test"):
        return _self_test()

    # Two transports, and which one is right depends on the client.
    #
    # stdio (the default) is what llama.cpp uses: it spawns this file as a child
    # process, speaks JSON-RPC over the pipes, and stops it again. There is no
    # service, no port, and nothing to start — llama.cpp's documentation is
    # explicit that only stdio is supported for the server's MCP feature.
    #
    # http exists for clients that want a URL instead — Open WebUI, OpenCode, and
    # the `rag` switch's own tests. It is opt-in because it is the heavier
    # option: a process to supervise and a port to look after.
    transport = "http" if "--http" in sys.argv else "stdio"
    as_http = os.environ.get("RAG_TRANSPORT", "").lower() == "http"
    if as_http:
        transport = "http"

    if transport == "stdio":
        # stdout is the protocol channel here. Anything printed to it would be
        # read as a malformed JSON-RPC frame, so diagnostics must go to stderr.
        print("rag: serving MCP over stdio", file=sys.stderr, flush=True)
        server.run(transport="stdio")
        return 0

    import uvicorn  # imported here so stdio mode drags in no server stack

    # Write our own pidfile before serving. The switch cannot use $! for this:
    # setsid is often already a process-group leader, so it forks and the shell's
    # $! names a process that exits immediately. Reporting liveness from the one
    # process that actually knows its own identity is the reliable way.
    pid_file = os.environ.get("RAG_PID_FILE", "")
    if pid_file:
        try:
            Path(pid_file).write_text(str(os.getpid()))
        except OSError as e:
            print(f"rag: cannot write pidfile {pid_file}: {e}", file=sys.stderr)

    app = server.streamable_http_app()
    print(f"rag: serving MCP on http://{HOST}:{PORT}/mcp", flush=True)
    try:
        uvicorn.run(app, host=HOST, port=PORT, log_level="warning", access_log=False)
    finally:
        if pid_file:
            try:
                Path(pid_file).unlink(missing_ok=True)
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
