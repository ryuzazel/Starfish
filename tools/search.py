#!/usr/bin/env python3
"""Starfish - ferramenta `search`: devolve resultados numerados (titulo, URL, trecho).

Uso:
  python3 tools/search.py                  le a consulta de starfish_workspace/tool_arg.txt (modo Starfish)
  python3 tools/search.py termos aqui      consulta pela linha de comando (modo terminal)
  python3 tools/search.py --debug termos   mostra o que cada backend respondeu
  python3 tools/search.py --selftest       testa os parsers com paginas de exemplo (sem internet)

Cadeia de backends (o primeiro que devolver resultado ganha):
  1. SearXNG proprio, se STARFISH_SEARCH_URL estiver definida
       export STARFISH_SEARCH_URL='http://localhost:8888/search?format=json&q='
  2. DuckDuckGo Lite   (POST)       3. DuckDuckGo HTML (POST)
  4. Mojeek                         5. Bing
  6. Wikipedia (API JSON; confiavel, bom para fatos)

Outras variaveis:
  STARFISH_SEARCH_LANG   idioma da busca (padrao: pt). Ex.: en
  STARFISH_SEARCH_ORDER  ordem dos backends, ex.: "mojeek,bing,wikipedia"

Convencao: em falha total a primeira linha da saida comeca com "ERROR:".
Formato de cada resultado (o agente depende dele):  N. titulo / '   URL: ...' / '   trecho'
"""
import os, sys, re, json, html, base64, urllib.parse, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARGFILE = os.path.join(ROOT, "starfish_workspace", "tool_arg.txt")
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/124.0 Safari/537.36")
LANG = (os.environ.get("STARFISH_SEARCH_LANG") or "pt").lower()[:2]
MAXRES = 8
DEBUG = False


class Blocked(Exception):
    """Pagina de bloqueio / captcha / limite de uso."""


# ----------------------------------------------------------------------------- utilidades
def clean(s):
    return html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", s or ""))).strip()


def attr(attrs, name):
    m = re.search(r"""\b%s\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""" % name, attrs, re.I)
    if not m:
        return ""
    return html.unescape(m.group(1) or m.group(2) or m.group(3) or "")


def anchors(body):
    """Todos os <a ...>texto</a> como (atributos, texto interno)."""
    return re.findall(r"<a\b([^>]*)>(.*?)</a>", body, re.S | re.I)


def http(url, data=None, timeout=15):
    headers = {"User-Agent": UA, "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
               "Accept-Language": "%s-BR,%s;q=0.9,en;q=0.7" % (LANG, LANG)}
    if data is not None:
        data = urllib.parse.urlencode(data).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        return r.status, r.read(2_000_000).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        if e.code in (202, 403, 429, 503):
            raise Blocked("HTTP %d (bloqueio anti-bot ou limite de uso)" % e.code)
        raise RuntimeError("HTTP %d" % e.code)


def looks_blocked(body):
    low = body[:6000].lower()
    return any(k in low for k in ("captcha", "unusual traffic", "anomaly", "are you a human",
                                  "detected unusual", "verify you are", "challenge-form"))


def real_url(href):
    """Desfaz redirecionadores de buscadores (DuckDuckGo uddg=, Bing u=a1...)."""
    if not href:
        return ""
    href = html.unescape(href)
    if href.startswith("//"):
        href = "https:" + href
    m = re.search(r"[?&]uddg=([^&]+)", href)
    if m:
        return urllib.parse.unquote(m.group(1))
    if "bing.com/ck/a" in href:
        m = re.search(r"[?&]u=([^&]+)", href)
        if m:
            v = urllib.parse.unquote(m.group(1))
            if v.startswith("a1"):
                v = v[2:]
                try:
                    return base64.urlsafe_b64decode(v + "=" * (-len(v) % 4)).decode("utf-8", "replace")
                except Exception:
                    pass
    return href


def good(url):
    return url.startswith("http") and "duckduckgo.com/y.js" not in url and "/aclk?" not in url


# ----------------------------------------------------------------------------- parsers (puros)
def parse_searxng(body):
    out = []
    for r in json.loads(body).get("results", [])[:MAXRES]:
        out.append((clean(r.get("title", "")), r.get("url", ""), clean(r.get("content", ""))))
    return out


def parse_ddg_lite(body):
    links = []
    for a, inner in anchors(body):
        if "result-link" in attr(a, "class"):
            links.append((clean(inner), real_url(attr(a, "href"))))
    snips = [clean(s) for s in re.findall(r"""class=['"]result-snippet['"][^>]*>(.*?)</td>""", body, re.S)]
    return [(t, u, snips[i] if i < len(snips) else "") for i, (t, u) in enumerate(links) if good(u)]


def parse_ddg_html(body):
    links = []
    for a, inner in anchors(body):
        if "result__a" in attr(a, "class"):
            links.append((clean(inner), real_url(attr(a, "href"))))
    snips = [clean(s) for s in re.findall(
        r"""class=['"]result__snippet['"][^>]*>(.*?)</(?:a|td|div)>""", body, re.S)]
    return [(t, u, snips[i] if i < len(snips) else "") for i, (t, u) in enumerate(links) if good(u)]


def parse_mojeek(body):
    links = []
    for a, inner in anchors(body):
        cls = attr(a, "class").split()
        href = attr(a, "href")
        if "title" in cls and href.startswith("http") and "mojeek." not in href:
            links.append((clean(inner), href))
    snips = [clean(s) for s in re.findall(r"""<p\s+class=['"]s['"][^>]*>(.*?)</p>""", body, re.S)]
    return [(t, u, snips[i] if i < len(snips) else "") for i, (t, u) in enumerate(links)]


def parse_bing(body):
    out = []
    for blk in re.split(r"""<li\s+class=['"]b_algo['"]""", body)[1:]:
        m = re.search(r"<h2[^>]*>\s*<a\b([^>]*)>(.*?)</a>", blk, re.S | re.I)
        if not m:
            continue
        url = real_url(attr(m.group(1), "href"))
        p = re.search(r"<p[^>]*>(.*?)</p>", blk, re.S | re.I)
        out.append((clean(m.group(2)), url, clean(p.group(1)) if p else ""))
    return out


def parse_wikipedia(body, lang):
    out = []
    for r in json.loads(body).get("query", {}).get("search", [])[:MAXRES]:
        t = r.get("title", "")
        url = "https://%s.wikipedia.org/wiki/%s" % (lang, urllib.parse.quote(t.replace(" ", "_")))
        out.append((t, url, clean(r.get("snippet", ""))))
    return out


# ----------------------------------------------------------------------------- backends (rede)
def b_searxng(q):
    base = os.environ.get("STARFISH_SEARCH_URL")
    if not base:
        return None
    _, body = http(base + urllib.parse.quote_plus(q))
    if body.lstrip().startswith("{"):
        return parse_searxng(body)
    raise RuntimeError("STARFISH_SEARCH_URL nao devolveu JSON (use ...?format=json&q=)")


def b_ddg_lite(q):
    _, body = http("https://lite.duckduckgo.com/lite/", {"q": q, "kl": "br-pt" if LANG == "pt" else "wt-wt"})
    r = parse_ddg_lite(body)
    if not r and looks_blocked(body):
        raise Blocked("pagina de verificacao/captcha")
    return r


def b_ddg_html(q):
    _, body = http("https://html.duckduckgo.com/html/", {"q": q, "kl": "br-pt" if LANG == "pt" else "wt-wt"})
    r = parse_ddg_html(body)
    if not r and looks_blocked(body):
        raise Blocked("pagina de verificacao/captcha")
    return r


def b_mojeek(q):
    _, body = http("https://www.mojeek.com/search?q=" + urllib.parse.quote_plus(q))
    r = parse_mojeek(body)
    if not r and looks_blocked(body):
        raise Blocked("bloqueio")
    return r


def b_bing(q):
    _, body = http("https://www.bing.com/search?q=%s&setlang=%s" % (urllib.parse.quote_plus(q), LANG))
    r = parse_bing(body)
    if not r and looks_blocked(body):
        raise Blocked("bloqueio")
    return r


def b_wikipedia(q):
    langs = [LANG] + (["en"] if LANG != "en" else [])
    for lg in langs:
        url = ("https://%s.wikipedia.org/w/api.php?action=query&list=search&format=json&utf8=1&srlimit=%d&srsearch=%s"
               % (lg, MAXRES, urllib.parse.quote_plus(q)))
        _, body = http(url)
        r = parse_wikipedia(body, lg)
        if r:
            return r
    return []


BACKENDS = [("searxng", b_searxng), ("ddg-lite", b_ddg_lite), ("ddg-html", b_ddg_html),
            ("mojeek", b_mojeek), ("bing", b_bing), ("wikipedia", b_wikipedia)]


def ordered():
    order = [x.strip() for x in (os.environ.get("STARFISH_SEARCH_ORDER") or "").split(",") if x.strip()]
    if not order:
        return BACKENDS
    byname = dict(BACKENDS)
    return [(n, byname[n]) for n in order if n in byname]


def search(q):
    """Devolve (backend, resultados, motivos_das_falhas)."""
    why = []
    for name, fn in ordered():
        try:
            res = fn(q)
        except Blocked as e:
            why.append("%s: %s" % (name, e)); res = None
        except Exception as e:
            why.append("%s: %s" % (name, re.sub(r"<urlopen error (?:\[Errno -?\d+\] )?(.*)>", r"\1", str(e))[:60])); res = None
        if res is None:
            if DEBUG and name != "searxng":
                print("[debug] %s -> falhou (%s)" % (name, why[-1]), file=sys.stderr)
            continue
        res = [r for r in res if r[1]][:MAXRES]
        if DEBUG:
            print("[debug] %s -> %d resultados" % (name, len(res)), file=sys.stderr)
        if res:
            return name, res, why
        why.append("%s: 0 resultados (a pagina mudou?)" % name)
    return None, [], why


# ----------------------------------------------------------------------------- selftest
def selftest():
    ok = True

    def check(label, got, want_url):
        nonlocal ok
        hit = bool(got) and got[0][1] == want_url
        ok = ok and hit
        print("%-10s %s  %s" % (label, "ok  " if hit else "FALHOU", got[:1]))

    check("ddg-lite", parse_ddg_lite(
        """<table><tr><td valign="top">1.&nbsp;</td><td><a rel="nofollow" href="https://exemplo.com/a" class='result-link'>Titulo <b>A</b></a></td></tr>
        <tr><td>&nbsp;</td><td class='result-snippet'>Trecho <b>um</b></td></tr></table>"""), "https://exemplo.com/a")
    check("ddg-html", parse_ddg_html(
        """<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexemplo.com%2Fb&amp;rut=x">Titulo B</a>
        <a class="result__snippet" href="x">Trecho dois</a>"""), "https://exemplo.com/b")
    check("mojeek", parse_mojeek(
        """<ul class="results-standard"><li><a class="ob" href="https://exemplo.com/c">exemplo.com</a>
        <h2><a class="title" href="https://exemplo.com/c">Titulo C</a></h2><p class="s">Trecho <b>tres</b></p></li></ul>"""),
        "https://exemplo.com/c")
    enc = base64.urlsafe_b64encode(b"https://exemplo.com/d").decode().rstrip("=")
    check("bing", parse_bing(
        """<li class="b_algo" data-id><h2><a href="https://www.bing.com/ck/a?!&amp;u=a1%s&amp;ntb=1">Titulo D</a></h2>
        <div class="b_caption"><p>Trecho quatro</p></div></li>""" % enc), "https://exemplo.com/d")
    check("wikipedia", parse_wikipedia(json.dumps({"query": {"search": [
        {"title": "Estrela do mar", "snippet": "uma <span>estrela</span>"}]}}), "pt"),
        "https://pt.wikipedia.org/wiki/Estrela_do_mar")
    check("searxng", parse_searxng(json.dumps({"results": [
        {"title": "E", "url": "https://exemplo.com/e", "content": "x"}]})), "https://exemplo.com/e")
    print("selftest:", "TUDO OK" if ok else "HOUVE FALHAS")
    return 0 if ok else 1


# ----------------------------------------------------------------------------- main
def main():
    global DEBUG
    args = sys.argv[1:]
    if args and args[0] == "--selftest":
        sys.exit(selftest())
    if args and args[0] == "--debug":
        DEBUG = True
        args = args[1:]
    if args:
        q = " ".join(args).strip()
    else:
        try:
            q = open(ARGFILE, encoding="utf-8").readline().strip()
        except Exception:
            q = ""
    if not q:
        print("ERROR: busca vazia")
        return
    name, res, why = search(q)
    if not res:
        print("ERROR: nenhum resultado em nenhum backend (%s). Dica: rode './starfish_tank.sh doctor' "
              "ou defina STARFISH_SEARCH_URL com um SearXNG." % "; ".join(why[-3:]))
        return
    for i, (t, u, s) in enumerate(res, 1):
        print("%d. %s\n   URL: %s\n   %s" % (i, t, u, s[:300]))
    print("[busca via %s]" % name)


if __name__ == "__main__":
    main()
