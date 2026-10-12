#!/usr/bin/env python3
"""Starfish - TERMINAL REAL do braco operador (ferramenta `sh`).

Executa qualquer comando bash (pipes, &&, redirecionamentos, curl, pip, git, python3, ...).
  python3 tools/term.py            le o comando de starfish_workspace/tool_arg.txt (modo Starfish)
  python3 tools/term.py -c 'ls'    executa direto (modo terminal)
  python3 tools/term.py --reset    zera a sessao (volta para Starfish_Work/ e limpa as variaveis)

SESSAO PERSISTENTE: o diretorio atual (cd) e as variaveis exportadas (export X=1) valem para os
proximos comandos, como num terminal de verdade. Comeca em starfish_workspace/Starfish_Work/.
Os helpers `search "consulta"` e `web URL` ficam no PATH (tools/bin), entao dentro do terminal o
agente pesquisa e le paginas com o mesmo codigo da ferramenta search/web.

Variaveis:
  STARFISH_TERM_MODE     guarded (padrao) | free | off
                           guarded: roda tudo, menos uma lista de comandos catastroficos
                           free:    sem nenhuma trava
                           off:     desliga o terminal
  STARFISH_CMD_TIMEOUT   segundos por comando (padrao 60)
  STARFISH_TERM_MAXOUT   bytes de saida devolvidos (padrao 20000)

Saida: texto do comando, depois "[cwd /caminho]" e SEMPRE a ultima linha "[exit N]".
Erros do proprio terminal (bloqueado, desligado) comecam com "ERROR:".

ISOLAMENTO (STARFISH_JAIL, padrao "on"): todo comando roda dentro de um bubblewrap (bwrap) em que a
UNICA pasta gravavel e starfish_workspace/Starfish_Work/. O resto do disco simplesmente nao existe la
dentro: o sistema (/usr, /bin, /lib, /etc) aparece somente-leitura, seu $HOME, suas chaves e os outros
projetos ficam invisiveis, e o ambiente e limpo (nenhuma variavel sua vaza). HOME = Starfish_Work.
A rede continua liberada (curl/pip/search/web). Se o bwrap nao existir, o terminal RECUSA rodar
(falha fechada) em vez de rodar solto. STARFISH_JAIL=off desliga o isolamento (nao recomendado).
Instale com: sudo pacman -S bubblewrap (Arch) | sudo apt install bubblewrap (Debian/Ubuntu)
"""
import os, sys, re, json, time, shlex, signal, shutil, subprocess, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WS = os.path.join(ROOT, "starfish_workspace")
SANDBOX = os.path.realpath(os.path.join(WS, "Starfish_Work"))   # a unica pasta que o agente enxerga/grava
JAIL = (os.environ.get("STARFISH_JAIL") or "on").lower() != "off"
BWRAP = shutil.which("bwrap")
ARGFILE = os.path.join(WS, "tool_arg.txt")
SESSION = os.path.join(WS, ".term_session.json")
AUDIT = os.path.join(WS, "term.log")
MODE = (os.environ.get("STARFISH_TERM_MODE") or "guarded").lower()
TIMEOUT = int(os.environ.get("STARFISH_CMD_TIMEOUT") or 60)
MAXOUT = int(os.environ.get("STARFISH_TERM_MAXOUT") or 20000)

# so para nao poluir o diff do ambiente entre comandos
IGNORE_ENV = {"_", "SHLVL", "PWD", "OLDPWD", "PS1", "BASH_EXECUTION_STRING", "BASHOPTS", "SHELLOPTS"}

# rede de seguranca do modo guarded: (regex, motivo). Casa contra o comando inteiro.
BLOCK = [
    (r"\brm\s+(-[a-zA-Z]*\s+)*(--no-preserve-root|/\s*$|/\*|~/?\s*$|~/\*|\$HOME/?\s*$|\$HOME/\*)", "apagar raiz/home"),
    (r"\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*\s+)+/(bin|boot|dev|etc|lib\w*|opt|proc|root|sbin|sys|usr|var)\b", "apagar diretorio do sistema"),
    (r"\bmkfs(\.\w+)?\b", "formatar disco"),
    (r"\bdd\b[^|;&]*\bof=/dev/", "escrever direto em dispositivo"),
    (r">\s*/dev/(sd|nvme|vd|hd|mmcblk)", "escrever direto em disco"),
    (r":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:", "fork bomb"),
    (r"\b(shutdown|reboot|poweroff|halt|init\s+[06])\b", "desligar/reiniciar a maquina"),
    (r"\bchmod\s+(-[a-zA-Z]+\s+)*[0-7]*777\s+/\s*$", "chmod 777 na raiz"),
    (r"\bchown\s+-[a-zA-Z]*R[a-zA-Z]*\s+\S+\s+/\s*$", "chown recursivo na raiz"),
    (r"\bkill\s+(-\w+\s+)*-1\b", "matar todos os processos"),
    (r"\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z|da|k)?sh\b", "baixar e executar direto (curl | sh)"),
    (r"(^|[;&|]\s*)(sudo|su|doas)\b", "escalar privilegios"),
    (r"\b(crontab\s+-r|systemctl\s+(disable|mask|stop)\b)", "mexer em servicos/agendamentos do sistema"),
]


def say(msg):
    print(msg)


def inside(path):
    """True se path existe e esta dentro de Starfish_Work (ou e ela)."""
    try:
        rp = os.path.realpath(path)
        return os.path.isdir(rp) and (rp == SANDBOX or rp.startswith(SANDBOX + os.sep))
    except Exception:
        return False


def load_session():
    try:
        d = json.load(open(SESSION, encoding="utf-8"))
        if inside(d.get("cwd", "")):
            return d
    except Exception:
        pass
    return {"cwd": SANDBOX, "env": {}}


def save_session(d):
    try:
        json.dump(d, open(SESSION, "w", encoding="utf-8"))
    except Exception:
        pass


def audit(cwd, cmd, rc, secs):
    try:
        one = " ".join(cmd.split())[:500]
        with open(AUDIT, "a", encoding="utf-8") as f:
            f.write("%s | rc=%s | %.1fs | %s | %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), rc, secs, cwd, one))
    except Exception:
        pass


def blocked_reason(cmd):
    if MODE == "free":
        return ""
    for rx, why in BLOCK:
        if re.search(rx, cmd):
            return why
    return ""


def base_env(extra):
    binp = os.path.join(ROOT, "tools", "bin")
    if JAIL:   # ambiente LIMPO: nada do seu ambiente (tokens, chaves, HOME real) entra no jail
        env = {"PATH": binp + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": SANDBOX,
               "USER": "starfish", "LANG": os.environ.get("LANG", "C.UTF-8")}
    else:
        env = dict(os.environ)
        env["PATH"] = binp + os.pathsep + env.get("PATH", "")
    env.update({"TERM": "dumb", "NO_COLOR": "1", "PAGER": "cat", "GIT_PAGER": "cat", "GIT_TERMINAL_PROMPT": "0",
                "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1", "DEBIAN_FRONTEND": "noninteractive",
                "STARFISH_ROOT": os.path.join(ROOT, "tools")})
    env.update(extra)
    return env


DUMP_IN_JAIL = "/run/sfdump"


def jail_argv(script, cwd, env, dumpdir):
    """Monta o comando bwrap. So Starfish_Work (e a pasta de dumps da sessao) sao gravaveis."""
    a = [BWRAP, "--die-with-parent", "--new-session", "--unshare-pid", "--unshare-ipc", "--unshare-uts",
         "--clearenv", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/run"]
    for d in ("/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/etc", "/opt"):
        if os.path.lexists(d):
            if os.path.islink(d):
                a += ["--symlink", os.readlink(d), d]
            else:
                a += ["--ro-bind", d, d]
    # DNS: em Arch/systemd-resolved o /etc/resolv.conf e symlink para /run/...; como /run e tmpfs, monta o alvo real
    try:
        rr = os.path.realpath("/etc/resolv.conf")
        if os.path.islink("/etc/resolv.conf") and not rr.startswith("/etc/") and os.path.isfile(rr):
            a += ["--ro-bind", rr, rr]
    except Exception:
        pass
    a += ["--ro-bind", os.path.join(ROOT, "tools"), os.path.join(ROOT, "tools")]   # helpers search/web
    a += ["--bind", SANDBOX, SANDBOX, "--bind", dumpdir, DUMP_IN_JAIL, "--chdir", cwd]
    for k, v in env.items():
        a += ["--setenv", k, v]
    return a + ["bash", "-c", script]


def jail_check():
    """Devolve '' se o bwrap funciona, senao o motivo."""
    if not BWRAP:
        return "bwrap nao encontrado (Arch: sudo pacman -S bubblewrap)"
    try:
        r = subprocess.run([BWRAP, "--ro-bind", "/usr", "/usr", "--symlink", "usr/bin", "/bin",
                            "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
                            "--unshare-pid", "--proc", "/proc", "true"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        if r.returncode != 0:
            return "bwrap nao conseguiu criar o isolamento: " + r.stderr.decode("utf-8", "replace").strip()[:200]
    except Exception as e:
        return "bwrap falhou: %s" % str(e)[:150]
    return ""


def cut(text):
    b = text.encode("utf-8", "replace")
    if len(b) <= MAXOUT:
        return text
    head, tail = int(MAXOUT * 0.6), int(MAXOUT * 0.4)
    return (b[:head].decode("utf-8", "ignore") + "\n[... %d bytes omitidos ...]\n" % (len(b) - head - tail)
            + b[-tail:].decode("utf-8", "ignore"))


def run(cmd):
    if MODE == "off":
        say("ERROR: terminal desligado (STARFISH_TERM_MODE=off)")
        return
    cmd = cmd.strip("\r\n")
    if not cmd.strip():
        say("ERROR: comando vazio")
        return
    why = blocked_reason(cmd)
    if why:
        audit("-", cmd, "BLOCKED", 0)
        say("ERROR: comando bloqueado pela rede de seguranca (%s). Use um comando mais especifico "
            "ou STARFISH_TERM_MODE=free se for isso mesmo que voce quer." % why)
        return

    os.makedirs(SANDBOX, exist_ok=True)
    if JAIL:
        why = jail_check()
        if why:
            say("ERROR: terminal recusado: isolamento indisponivel (%s). Nada foi executado. "
                "Para rodar sem isolamento (nao recomendado): STARFISH_JAIL=off" % why)
            return
    sess = load_session()
    dumpdir = tempfile.mkdtemp(prefix="term_dump_")
    envdump, cwddump = os.path.join(dumpdir, "env"), os.path.join(dumpdir, "cwd")
    wenv, wcwd = (os.path.join(DUMP_IN_JAIL, "env"), os.path.join(DUMP_IN_JAIL, "cwd")) if JAIL else (envdump, cwddump)
    # o trap grava cwd e ambiente ao sair, mesmo se o comando chamar `exit`
    script = "trap 'rc=$?; pwd > %s; env -0 > %s; exit $rc' EXIT\n%s\n" % (
        shlex.quote(wcwd), shlex.quote(wenv), cmd)
    t0 = time.time()
    timed_out = False
    try:
        benv = base_env(sess.get("env", {}))
        argv = jail_argv(script, sess["cwd"], benv, dumpdir) if JAIL else ["bash", "-c", script]
        p = subprocess.Popen(argv, cwd=sess["cwd"], env=({} if JAIL else benv),
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             start_new_session=True)
        try:
            out, _ = p.communicate(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except Exception:
                pass
            out, _ = p.communicate()
        rc = 124 if timed_out else p.returncode
    except Exception as e:
        say("ERROR: nao consegui executar: %s" % str(e)[:200])
        return
    secs = time.time() - t0

    # atualiza a sessao (cwd + variaveis que mudaram)
    try:
        newcwd = open(cwddump, encoding="utf-8").read().strip()
        if newcwd and inside(newcwd):
            sess["cwd"] = os.path.realpath(newcwd)
        raw = open(envdump, "rb").read().split(b"\0")
        after = {}
        for item in raw:
            if b"=" in item:
                k, v = item.split(b"=", 1)
                after[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
        before = base_env(sess.get("env", {}))
        changed = {k: v for k, v in after.items() if k not in IGNORE_ENV and before.get(k) != v
                   and not k.startswith("BASH_FUNC_") and k not in ("PATH",)}
        sess.setdefault("env", {}).update(changed)
        save_session(sess)
    except Exception:
        pass
    finally:
        shutil.rmtree(dumpdir, ignore_errors=True)

    audit(sess["cwd"], cmd, rc, secs)
    text = cut(out.decode("utf-8", "replace").rstrip("\n"))
    if text:
        say(text)
    if timed_out:
        say("[timeout apos %ds - processo encerrado]" % TIMEOUT)
    say("[cwd %s]" % sess["cwd"])
    say("[exit %d]" % rc)


def main():
    a = sys.argv[1:]
    if a and a[0] == "--reset":
        for f in (SESSION,):
            try:
                os.unlink(f)
            except Exception:
                pass
        say("sessao do terminal zerada (cwd = %s)" % SANDBOX)
        return
    if a and a[0] == "-c" and len(a) > 1:
        run(" ".join(a[1:]))
        return
    try:
        cmd = open(ARGFILE, encoding="utf-8").read()
    except Exception:
        cmd = ""
    run(cmd)


if __name__ == "__main__":
    main()
