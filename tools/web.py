#!/usr/bin/env python3
"""Starfish - ferramenta `web`: baixa uma pagina e devolve so o texto.
Argumento em starfish_workspace/tool_arg.txt (modo Starfish) ou como 1o argumento (modo terminal).
So internet publica: cada URL (inclusive cada redirecionamento) tem o host resolvido e
rejeitado se for loopback, rede privada, link-local (metadados de nuvem) ou reservado.
Convencao: em falha a primeira linha da saida comeca com "ERROR:"."""
import os, sys, re, html, socket, ipaddress, urllib.request, urllib.parse, urllib.error
from html.parser import HTMLParser

ARGFILE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "starfish_workspace", "tool_arg.txt")
MAXCHARS, MAXBYTES, MAXHOPS, TIMEOUT = 20000, 3_000_000, 5, 20

def fail(msg):
    print("ERROR: " + msg); sys.exit(0)

def check(url):
    p = urllib.parse.urlsplit(url)
    if p.scheme not in ("http", "https") or not p.hostname:
        fail("so aceito URLs http:// ou https://")
    try:
        infos = socket.getaddrinfo(p.hostname, p.port or (443 if p.scheme == "https" else 80))
    except Exception as e:
        fail("nao consegui resolver %s" % p.hostname)
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if not ip.is_global:
            fail("host nao permitido (%s -> %s): rede local bloqueada" % (p.hostname, ip))

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None

if len(sys.argv) > 1:                       # modo terminal: web https://...
    url = sys.argv[1].strip()
else:                                       # modo Starfish: argumento em tool_arg.txt
    try:
        url = open(ARGFILE, encoding="utf-8").readline().strip()
    except Exception:
        fail("sem argumento")
if not url: fail("URL vazia")

opener = urllib.request.build_opener(NoRedirect)
body, ctype = b"", ""
for hop in range(MAXHOPS + 1):
    check(url)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"})
    try:
        r = opener.open(req, timeout=TIMEOUT)
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location"):
            url = urllib.parse.urljoin(url, e.headers["Location"]); continue
        fail("HTTP %d em %s" % (e.code, url))
    except Exception as e:
        fail("falha ao baixar: %s" % str(e)[:200])
    ctype = r.headers.get("Content-Type", "")
    body = r.read(MAXBYTES)
    break
else:
    fail("redirecionamentos demais")

if ctype and not re.search(r"text|html|json|xml", ctype, re.I):
    fail("tipo nao textual: " + ctype)
raw = body.decode("utf-8", "replace")

class P(HTMLParser):
    SKIP = ("script", "style", "noscript", "svg", "head", "nav")
    BLOCK = ("p", "br", "div", "li", "tr", "h1", "h2", "h3", "h4", "pre")
    def __init__(s): super().__init__(); s.out = []; s.skip = 0
    def handle_starttag(s, t, a):
        if t in s.SKIP: s.skip += 1
        if t in s.BLOCK: s.out.append("\n")
    def handle_endtag(s, t):
        if t in s.SKIP and s.skip: s.skip -= 1
        if t in s.BLOCK: s.out.append("\n")
    def handle_data(s, d):
        if not s.skip: s.out.append(d)

if re.search(r"<(html|body|p|div)\b", raw[:5000], re.I):
    p = P(); p.feed(raw); text = "".join(p.out)
else:
    text = raw
text = html.unescape(text)
text = re.sub(r"[ \t\r\f\v]+", " ", text)
text = re.sub(r"\n\s*\n+", "\n", text).strip()
# tira o "lixo de topo" (menus, breadcrumbs): antes do primeiro paragrafo longo, descarta linhas curtas
_ln = text.split("\n")
_i = next((k for k, l in enumerate(_ln) if len(l.strip()) >= 80), 0)
if _i > 0:
    text = "\n".join([l for l in _ln[:_i] if len(l.strip()) >= 25] + _ln[_i:]).strip()
print(text[:MAXCHARS] if text else "ERROR: pagina sem texto")