#!/usr/bin/env bash
# starfish_tank.sh — o aquário do Starfish: sobe, conversa, acompanha, depura.
#
# DIA A DIA
#   ./starfish_tank.sh start | stop | restart      sobe/para o Starfish em segundo plano
#   ./starfish_tank.sh chat                        conversa interativa (agente + terminal + busca)
#   ./starfish_tank.sh agent  "baixe X e me diga Y"   agente com TERMINAL REAL e busca
#   ./starfish_tank.sh code   "ordene um csv"         programador escreve, operador roda, erro volta (py/bash)
#   ./starfish_tank.sh research "pergunta"            pesquisa na web e responde citando fontes
#   ./starfish_tank.sh ask|gen "texto"                resposta curta | longa revisada em partes
#
# TERMINAL (sessão compartilhada com o agente: cd e export valem para os dois)
#   ./starfish_tank.sh term                        shell interativo na sessão do Starfish
#   ./starfish_tank.sh term "ls -la"               roda um comando direto, sem passar pelo servidor
#   ./starfish_tank.sh sh "uname -a"               roda via servidor (o braço operador executa)
#   ./starfish_tank.sh run  arquivo.py             roda um arquivo do sandbox (.py .sh ...)
#   ./starfish_tank.sh audit                       acompanha o log de TODOS os comandos executados
#
# BUSCA E WEB
#   ./starfish_tank.sh search "consulta"           busca local (use --debug para ver cada backend)
#   ./starfish_tank.sh web https://pagina          texto de uma página
#
# ESTADO
#   ./starfish_tank.sh status | watch | log | skills | context | doctor
#   ./starfish_tank.sh result [ID]                 resultado de uma task (sem ID: a última)
#   ./starfish_tank.sh send "ferramenta:arg"       envia sem esperar
#   ./starfish_tank.sh skill list|show NOME|novo "tema"|NOME "tarefa"
#   ./starfish_tank.sh mem list|count|find "palavra"|add "regra"
#   ./starfish_tank.sh echo|read|write|http|save "argumento"
#   ./starfish_tank.sh reset                       apaga lições, skills, nível e sessão do terminal
#
# VARIÁVEIS (todas opcionais)
#   STARFISH_DIR        pasta do projeto (padrão: pasta deste script)
#   CNR                 caminho do interpretador CnR (padrão: CnR ou cnr no PATH)
#   STARFISH_URL        padrão http://localhost:7070
#   STARFISH_TIMEOUT    segundos de espera por task (padrão 3600)
#   STARFISH_TERM_MODE  guarded (padrão) | free (sem travas) | off (sem terminal)
#   STARFISH_CMD_TIMEOUT  segundos por comando do terminal (padrão 60)
#   STARFISH_SEARCH_URL   SearXNG próprio: 'http://localhost:8888/search?format=json&q='
#   STARFISH_SEARCH_LANG  idioma da busca (padrão pt)
#   NO_COLOR            desliga as cores
# Precisa de: bash, curl, python3.

set -u
DIR="${STARFISH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
URL="${STARFISH_URL:-http://localhost:7070}"
TIMEOUT="${STARFISH_TIMEOUT:-3600}"
PIDFILE="$DIR/.starfish.pid"
OUTFILE="$DIR/starfish.out"
HISTFILE_TANK="$DIR/.tank_history"
WS="$DIR/starfish_workspace"

if [ -n "${CNR:-}" ]; then BIN="$CNR"
elif command -v CnR >/dev/null 2>&1; then BIN="CnR"
elif command -v cnr >/dev/null 2>&1; then BIN="cnr"
else BIN="CnR"; fi

# ------------------------------------------------------------------ visual
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C0=$'\e[0m'; CB=$'\e[1m'; CD=$'\e[2m'; CR=$'\e[31m'; CG=$'\e[32m'; CY=$'\e[33m'
  CC=$'\e[36m'; CO=$'\e[38;5;208m'; COLOR=1
else
  C0=""; CB=""; CD=""; CR=""; CG=""; CY=""; CC=""; CO=""; COLOR=0
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); OKM="✔"; BADM="✘"; STAR="✦"; ARW="›" ;;
  *) SPIN=('|' '/' '-' '\'); OKM="ok"; BADM="falhou"; STAR="*"; ARW=">" ;;
esac

die()  { echo "${CR}erro:${C0} $*" >&2; exit 1; }
warn() { echo "${CY}aviso:${C0} $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "preciso do '$1' instalado"; }
need curl; need python3

banner() { echo "${CO}${CB}  $STAR starfish${C0} ${CD}— $*${C0}"; }

is_up() { curl -s -m 2 "$URL/status" >/dev/null 2>&1; }
need_up() { is_up || die "o Starfish não está respondendo em $URL. Rode: $0 start"; }

jget() { python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); v=d.get(sys.argv[1],"")
    print(v if not isinstance(v,(dict,list)) else json.dumps(v,ensure_ascii=False))
except Exception: print("")' "$1"; }

# imprime o rodapé [cwd ..]/[exit N] do terminal em cinza (e [exit != 0] em vermelho)
paint_footer() {
  if [ "$COLOR" = 1 ]; then
    sed -E "s/^(\[cwd .*\])$/${CD}\1${C0}/; s/^(\[exit 0\])$/${CG}\1${C0}/; s/^(\[exit [1-9][0-9]*\])$/${CR}\1${C0}/; s/^(\[timeout.*\])$/${CY}\1${C0}/; s/^(ERROR:.*)$/${CR}\1${C0}/"
  else cat; fi
}

# ------------------------------------------------------------------ subir / parar
cmd_start() {
  if is_up; then echo "${CG}$OKM${C0} o Starfish já está rodando em $URL"; return 0; fi
  [ -f "$DIR/STARFISH.cnr" ] || die "não achei STARFISH.cnr em $DIR (use STARFISH_DIR)"
  command -v "$BIN" >/dev/null 2>&1 || [ -x "$BIN" ] || die "não achei o interpretador '$BIN' (use CNR=/caminho/CnR)"
  mkdir -p "$WS" "$DIR/models" "$WS/Starfish_Work"
  [ -f "$DIR/models/model.gguf" ] || warn "sem models/model.gguf: vou tentar um llama-server já rodando em :8080"
  ( cd "$DIR" && nohup "$BIN" STARFISH.cnr >"$OUTFILE" 2>&1 & echo $! >"$PIDFILE" )
  local i=0 t0; t0=$(date +%s)
  while [ $i -lt 600 ]; do   # até 10 min: carregar o modelo pode demorar
    if is_up; then
      printf '\r\033[K' 2>/dev/null
      echo "${CG}$OKM${C0} pronto em $(( $(date +%s) - t0 ))s: ${CB}$URL${C0}  ${CD}(log: $DIR/starfish.log)${C0}"
      echo "  ${CD}próximo passo:${C0} $0 chat"
      return 0
    fi
    if [ -f "$PIDFILE" ] && ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo; echo "${CR}$BADM${C0} o Starfish encerrou ao subir. Saída:"; tail -n 15 "$OUTFILE"; return 1
    fi
    if [ -t 1 ]; then printf '\r%s subindo... %ss (carregar o modelo pode levar minutos)' "${SPIN[$((i % ${#SPIN[@]}))]}" "$(( $(date +%s) - t0 ))"; fi
    i=$((i + 1)); sleep 1
  done
  echo; die "demorou demais para subir; veja $OUTFILE e $DIR/llama-server.log"
}

cmd_stop() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE" && echo "${CG}$OKM${C0} Starfish parado."
  else
    echo "não achei um Starfish iniciado por este script (pidfile)."
    echo "se ele roda em outro terminal, use Ctrl+C lá."
  fi
}

# ------------------------------------------------------------------ tarefas
post_task() {
  python3 - "$URL" "$1" <<'PY'
import sys, json, urllib.request
url, task = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url + "/tasks", data=json.dumps({"task": task}).encode(), method="POST",
                             headers={"Content-Type": "application/json"})
try:
    print(json.load(urllib.request.urlopen(req, timeout=20))["taskId"])
except Exception as e:
    sys.exit("falha ao enviar: %s" % e)
PY
}

# uma consulta: "status<TAB>progresso"
poll_once() {
  python3 - "$URL" "$1" <<'PY'
import sys, json, urllib.request
url, i = sys.argv[1], sys.argv[2]
def g(p): return json.load(urllib.request.urlopen(url + p, timeout=8))
try:
    t = g("/tasks/" + i); s = g("/status")
    print(t.get("status", "?") + "\t" + str(s.get("progress", "")).replace("\n", " "))
except Exception:
    print("?\t")
PY
}

show_result() {
  COLORON="$COLOR" CB="$CB" CD="$CD" CG="$CG" CR="$CR" C0="$C0" CC="$CC" python3 -c '
import sys, json, os
E = os.environ
d = json.load(sys.stdin)
tools = {0:"read",1:"write",2:"http",3:"echo",4:"ask",5:"agent",6:"gen",7:"skill",8:"mem",13:"agent-step",
         14:"web",15:"search",16:"code",17:"save",18:"sh",19:"run",20:"research"}
st = d.get("status", "?")
col = E["CG"] if st == "done" else E["CR"]
t = tools.get(d.get("tool"), d.get("tool"))
ray = d.get("ray")
print("%s%s%s%s  %s(tool %s, braço %s)%s" % (col, E["CB"], st.upper(), E["C0"], E["CD"], t, ray if ray != -1 else "-", E["C0"]))
ev = [e for e in str(d.get("events", "")).split("\n") if e.strip()]
if ev:
    print("\n%s%s--- o que os braços fizeram ---%s" % (E["CD"], E["CB"], E["C0"]))
    for e in ev: print(" %s*%s %s" % (E["CC"], E["C0"], e))
print("\n%s%s--- resultado ---%s" % (E["CD"], E["CB"], E["C0"]))
print(d.get("result", ""))' <<<"$1" | paint_footer
}

# envia e espera, com spinner e progresso ao vivo. Ctrl+C solta a espera (a task continua no Starfish).
run_task() {
  local task="$1" nowait="${2:-0}"
  need_up
  local id; id=$(post_task "$task") || return 1
  echo "${CD}task $id →${C0} ${CB}$task${C0}"
  [ "$nowait" = "1" ] && { echo "veja depois: $0 result $id"; return 0; }
  local start now S P last="" k=0 cols line aborted=0
  start=$(date +%s)
  trap 'aborted=1' INT
  while [ $aborted = 0 ]; do
    IFS=$'\t' read -r S P <<<"$(poll_once "$id")"
    if [ "$S" = "done" ] || [ "$S" = "failed" ]; then break; fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$TIMEOUT" ]; then
      trap - INT; echo; echo "${CY}passou de ${TIMEOUT}s;${C0} a task continua no Starfish. Veja: $0 result $id"; return 2
    fi
    if [ -t 1 ]; then
      cols=$(tput cols 2>/dev/null || echo 80)
      line=$(printf '%s %3ss  %s' "${SPIN[$((k % ${#SPIN[@]}))]}" "$((now - start))" "${P:-na fila...}")
      printf '\r\033[K%s%s%s' "$CO" "${line:0:$((cols - 1))}" "$C0"
    elif [ -n "$P" ] && [ "$P" != "$last" ]; then
      printf '  [%ss] %s\n' "$((now - start))" "$P"; last="$P"
    fi
    k=$((k + 1)); sleep 0.5
  done
  trap - INT
  [ -t 1 ] && printf '\r\033[K'
  if [ $aborted = 1 ]; then echo; echo "${CY}solto.${C0} a task $id continua rodando. Veja: $0 result $id"; return 130; fi
  echo
  show_result "$(curl -s "$URL/tasks/$id")"
  echo; echo "${CD}(levou $(( $(date +%s) - start ))s)${C0}"
}

last_task_id() { curl -s -m 5 "$URL/status" | jget processed; }

cmd_result() {
  need_up
  local id="${1:-}"
  if [ -z "$id" ]; then id=$(last_task_id); [ -n "$id" ] && [ "$id" != "0" ] || die "ainda não há tasks concluídas"; fi
  show_result "$(curl -s "$URL/tasks/$id")"
}

# ------------------------------------------------------------------ estado
cmd_status() {
  need_up
  curl -s "$URL/status" | CB="$CB" CD="$CD" CG="$CG" CR="$CR" CO="$CO" C0="$C0" python3 -c '
import sys, json, re, os
E = os.environ
d = json.load(sys.stdin)
roles = {"E":"executor","V":"revisor","A":"arquivista","F":"ferreiro","P":"planejador","W":"pesquisador","C":"programador","O":"operador"}
print("%s%s✦ starfish%s  nível %s%s%s" % (E["CO"], E["CB"], E["C0"], E["CB"], d.get("level"), E["C0"]))
print(E["CD"] + str(d.get("summary")) + E["C0"])
run = d.get("running")
print("\nprocessadas %s | na fila %s | rodando %s" % (d.get("processed"), d.get("pending"), ("task %s" % run) if run else "nada"))
print("agora: %s" % d.get("progress"))
print("\n%s%-5s %-12s %-5s %-4s %-9s %-6s %-5s%s" % (E["CB"], "slot", "papel", "vivo", "ger", "ok/falha", "dor", "pts-", E["C0"]))
for m in re.finditer(r"R(\d+)([A-Z])([+x])g(\d+)\(ok (\d+)/falha (\d+)/dor ([\d.]+)/pts- (\d+)/cred (\d+)\)", str(d.get("rays", ""))):
    i, r, v, g, ok, fl, pain, pts, cr = m.groups()
    mark = (E["CG"] + "%-5s" % "sim" if v == "+" else E["CR"] + "%-5s" % "morto") + E["C0"]
    print("%-5s %-12s %s %-4s %-9s %-6s %-5s" % ("R"+i, roles.get(r, r), mark, g, ok+"/"+fl, pain, pts))'
}

cmd_watch() {
  need_up
  echo "acompanhando (Ctrl+C para sair)"
  local last="" P
  while true; do
    P=$(curl -s -m 5 "$URL/status" | jget progress)
    if [ "$P" != "$last" ]; then printf '%s  %s\n' "$(date +%H:%M:%S)" "$P"; last="$P"; fi
    sleep 1
  done
}

cmd_skills()  { need_up; curl -s "$URL/skills"  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("skills",""))'; }
cmd_context() { need_up; curl -s "$URL/context" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("lessons",""))'; }
cmd_log()     { [ -f "$DIR/starfish.log" ] || die "ainda não existe $DIR/starfish.log"; tail -n 40 -f "$DIR/starfish.log"; }
cmd_audit()   { [ -f "$WS/term.log" ] || die "nenhum comando executado ainda ($WS/term.log)"; tail -n 30 -f "$WS/term.log"; }

# ------------------------------------------------------------------ terminal local (mesma sessão do agente)
local_term() { python3 "$DIR/tools/term.py" -c "$*" | paint_footer; }

term_cwd() {
  python3 - "$WS/.term_session.json" "$WS/Starfish_Work" <<'PY'
import sys, json
try: print(json.load(open(sys.argv[1]))["cwd"])
except Exception: print(sys.argv[2])
PY
}

cmd_term() {
  if [ $# -gt 0 ]; then local_term "$*"; return; fi
  banner "terminal compartilhado com o agente"
  echo "${CD}  cd/export valem para o agente também. Modo: ${STARFISH_TERM_MODE:-guarded}. 'exit' ou Ctrl+D sai. Comandos aparecem em: $0 audit${C0}"
  local cwd line out
  cwd=$(term_cwd)
  history -c 2>/dev/null
  while true; do
    IFS= read -e -r -p $'\001'"$CC"$'\002'"${cwd/#$HOME/~}"$'\001'"$C0"$'\002'" \$ " line || { echo; break; }
    [ -z "${line// }" ] && continue
    case "$line" in exit|quit) break ;; esac
    history -s -- "$line"
    out=$(python3 "$DIR/tools/term.py" -c "$line")
    printf '%s\n' "$out" | paint_footer
    cwd=$(printf '%s\n' "$out" | sed -n 's/^\[cwd \(.*\)\]$/\1/p' | tail -n 1); [ -n "$cwd" ] || cwd=$(term_cwd)
  done
}

cmd_search() {
  python3 "$DIR/tools/search.py" "$@" | python3 -c '
import sys, os
E = os.environ
for l in sys.stdin.read().splitlines():
    if l.startswith("ERROR"): print(E.get("CR","") + l + E.get("C0",""))
    elif l.startswith("   URL:"): print(E.get("CC","") + l + E.get("C0",""))
    elif l.startswith("[busca via"): print(E.get("CD","") + l + E.get("C0",""))
    else: print(l)'
}

# ------------------------------------------------------------------ doctor
cmd_doctor() {
  banner "diagnóstico"
  local ok="${CG}$OKM${C0}" bad="${CR}$BADM${C0}" wn="${CY}!${C0}"
  echo "${CB}ambiente${C0}"
  echo "  $ok bash ${BASH_VERSION%%(*}, $(python3 --version 2>&1), curl $(curl --version | head -n1 | cut -d' ' -f2)"
  if command -v "$BIN" >/dev/null 2>&1 || [ -x "$BIN" ]; then echo "  $ok interpretador CnR: $BIN"
  else echo "  $bad interpretador CnR não encontrado ('$BIN'). Compile CnR.cpp (g++ -std=c++17 -pthread) e use CNR=/caminho"; fi
  local lsb="${LLAMA_SERVER_BIN:-llama-server}"
  if command -v "$lsb" >/dev/null 2>&1 || [ -x "$lsb" ]; then echo "  $ok llama-server: $lsb"
  else echo "  $wn llama-server não encontrado (necessário só se models/model.gguf existir)"; fi
  if [ -f "$DIR/models/model.gguf" ]; then echo "  $ok modelo: models/model.gguf ($(du -h "$DIR/models/model.gguf" | cut -f1))"
  elif curl -s -m 2 http://127.0.0.1:8080/health >/dev/null 2>&1; then echo "  $ok sem model.gguf, mas há um llama-server em :8080"
  else echo "  $bad sem models/model.gguf e sem llama-server em :8080 (as ferramentas com modelo vão falhar)"; fi
  if is_up; then echo "  $ok Starfish respondendo em $URL"; else echo "  $wn Starfish parado (rode: $0 start)"; fi

  echo; echo "${CB}terminal${C0}  ${CD}(modo ${STARFISH_TERM_MODE:-guarded})${C0}"
  local t; t=$(python3 "$DIR/tools/term.py" -c 'echo oi; python3 -c "print(6*7)"' 2>&1)
  if printf '%s' "$t" | grep -q '^42$' && printf '%s' "$t" | grep -q '^\[exit 0\]$'; then echo "  $ok bash + python3 executam (sessão em $(term_cwd))"
  else echo "  $bad terminal com problema:"; printf '%s\n' "$t" | sed 's/^/      /'; fi
  t=$(python3 "$DIR/tools/term.py" -c 'ls /home 2>&1; test -w /etc && echo ETC_GRAVAVEL; echo FIM' 2>&1)
  if [ "${STARFISH_JAIL:-on}" = "off" ]; then echo "  $wn isolamento DESLIGADO (STARFISH_JAIL=off): o terminal enxerga o disco inteiro"
  elif printf '%s' "$t" | grep -q '^ERROR'; then echo "  $bad isolamento indisponível: $(printf '%s' "$t" | head -n1)"
  else echo "  $ok isolado em Starfish_Work/ (bwrap): o resto do disco não é visível nem gravável"; fi
  t=$(python3 "$DIR/tools/term.py" -c 'rm -rf /' 2>&1 | head -n1)
  case "$t" in ERROR*) echo "  $ok rede de segurança ativa (bloqueia 'rm -rf /' e afins)" ;; *) echo "  $wn rede de segurança desligada (modo free/off)" ;; esac

  echo; echo "${CB}busca${C0}  ${CD}(consulta de teste: 'estrela do mar')${C0}"
  [ -n "${STARFISH_SEARCH_URL:-}" ] && echo "  ${CD}STARFISH_SEARCH_URL = $STARFISH_SEARCH_URL${C0}"
  local b out any=0 line
  for b in searxng ddg-lite ddg-html mojeek bing wikipedia; do
    [ "$b" = searxng ] && [ -z "${STARFISH_SEARCH_URL:-}" ] && continue
    out=$(STARFISH_SEARCH_ORDER="$b" python3 "$DIR/tools/search.py" "estrela do mar" 2>&1)
    if printf '%s' "$out" | grep -q '^\[busca via'; then
      echo "  $ok $(printf '%-10s' "$b") $(printf '%s' "$out" | grep -c '^   URL:') resultados"; any=1
    else
      line=$(printf '%s' "$out" | head -n1 | sed 's/^ERROR: nenhum resultado em nenhum backend (//; s/)\. Dica.*//' | cut -c1-90)
      echo "  $bad $(printf '%-10s' "$b") $line"
    fi
  done
  if [ $any = 0 ]; then
    echo "  ${CY}nenhum backend respondeu.${C0} Sem internet? Para um buscador próprio e estável:"
    echo "    docker run -d -p 8888:8080 searxng/searxng   ${CD}# habilite 'json' em search.formats no settings.yml${C0}"
    echo "    export STARFISH_SEARCH_URL='http://localhost:8888/search?format=json&q='"
  fi
  echo; python3 "$DIR/tools/search.py" --selftest | tail -n 1 | sed "s/^selftest: /  parsers: /"
}

# ------------------------------------------------------------------ chat
chat_help() {
  cat <<EOF
${CB}texto normal${C0}      vai para o agente (ele decide: terminal, busca, código...)
${CB}!comando${C0}         roda no terminal na hora (mesma sessão do agente), ex: !ls -la
${CB}/sh cmd${C0}          o braço operador roda o comando  ${CB}/run arq.py${C0}  roda um arquivo do sandbox
${CB}/code objetivo${C0}   programa em py/bash: escreve → roda → corrige
${CB}/research q${C0}      pesquisa na web e responde com fontes   ${CB}/search q${C0}  só os resultados   ${CB}/web url${C0}
${CB}/ask q${C0}  ${CB}/gen q${C0}   resposta curta | longa revisada   ${CB}/mem ...${C0}  ${CB}/skill ...${C0}
${CB}/status${C0}  ${CB}/skills${C0}  ${CB}/log${C0}  ${CB}/audit${C0}  ${CB}/result [id]${C0}  ${CB}/doctor${C0}   ${CB}/help${C0}   ${CB}/exit${C0}
${CD}Ctrl+C durante uma espera solta a task (ela continua) e volta ao prompt.${C0}
EOF
}

cmd_chat() {
  if ! is_up; then
    read -r -p "O Starfish não está rodando. Subir agora? [S/n] " a
    case "${a:-s}" in n|N) exit 1 ;; esac
    cmd_start || exit 1
  fi
  banner "chat — /help para os comandos, /exit para sair"
  history -c 2>/dev/null; history -r "$HISTFILE_TANK" 2>/dev/null
  local line
  while true; do
    IFS= read -e -r -p $'\001'"$CO"$'\002'"starfish"$'\001'"$C0"$'\002'" $ARW " line || { echo; break; }
    [ -z "${line// }" ] && continue
    history -s -- "$line"; printf '%s\n' "$line" >> "$HISTFILE_TANK"
    case "$line" in
      /exit|/quit|/q|exit|quit) break ;;
      /help|/\?|help) chat_help ;;
      !*) local_term "${line#!}" ;;
      /status) cmd_status ;;
      /skills) cmd_skills ;;
      /log) echo "${CD}(Ctrl+C volta ao chat)${C0}"; ( trap 'exit 0' INT; cmd_log ) ;;
      /audit) echo "${CD}(Ctrl+C volta ao chat)${C0}"; ( trap 'exit 0' INT; cmd_audit ) ;;
      /doctor) cmd_doctor ;;
      /result) cmd_result ;;
      /result\ *) cmd_result "${line#/result }" ;;
      /search\ *) cmd_search ${line#/search } ;;
      /web\ *) python3 "$DIR/tools/web.py" "${line#/web }" | head -n 60 ;;
      /agent\ *|/ask\ *|/gen\ *|/code\ *|/research\ *|/sh\ *|/run\ *|/mem\ *|/skill\ *|/read\ *|/write\ *|/save\ *|/http\ *|/echo\ *)
          local cmd="${line%% *}"; cmd="${cmd#/}"; run_task "$cmd:${line#* }" || true ;;
      /*) echo "${CY}comando desconhecido.${C0} /help lista os comandos." ;;
      *) run_task "agent:$line" || true ;;
    esac
  done
}

# ------------------------------------------------------------------ reset
cmd_reset() {
  echo "Isto apaga lições, skills, nível/XP, notas, a sessão do terminal e o starfish.log."
  echo "${CD}(os arquivos em starfish_workspace/Starfish_Work/ são mantidos)${C0}"
  read -r -p "Digite 'sim' para confirmar: " ans
  [ "$ans" = "sim" ] || { echo "cancelado."; return 1; }
  if is_up; then echo "parando o Starfish antes..."; cmd_stop; sleep 1; fi
  rm -f "$WS"/context.txt "$WS"/skills.txt "$WS"/estado.txt "$WS"/notes.txt "$WS"/progresso.txt \
        "$WS"/.term_session.json "$WS"/term.log "$WS"/tool_arg.txt "$DIR"/starfish.log
  echo "${CG}$OKM${C0} pronto. Rode: $0 start"
}

usage() { sed -n '2,/^# Precisa de/p' "$0" | sed 's/^# \{0,1\}//'; }

c="${1:-}"; [ $# -gt 0 ] && shift
case "$c" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_stop; sleep 1; cmd_start ;;
  chat) cmd_chat ;;
  term) cmd_term "$@" ;;
  search) [ $# -ge 1 ] || die "uso: $0 search [--debug] \"consulta\""; cmd_search "$@" ;;
  web) [ $# -ge 1 ] || die "uso: $0 web https://pagina"; python3 "$DIR/tools/web.py" "$1" ;;
  ask|gen|agent|research|code|sh|run|save|echo|read|write|http)
      [ $# -ge 1 ] || die "uso: $0 $c \"texto\""
      run_task "$c:$*" ;;
  skill)
      [ $# -ge 1 ] || die "uso: $0 skill list | show NOME | novo \"tema\" | NOME \"tarefa\""
      sub="$1"; shift
      case "$sub" in
        list) run_task "skill:list" ;;
        show) run_task "skill:show $*" ;;
        novo) run_task "skill:novo $*" ;;
        *)    [ $# -ge 1 ] || die "uso: $0 skill NOME \"tarefa\""
              run_task "skill:$sub|$*" ;;
      esac ;;
  mem)
      [ $# -ge 1 ] || die "uso: $0 mem list | count | find \"palavra\" | add \"regra\""
      run_task "mem:$*" ;;
  send) [ $# -ge 1 ] || die "uso: $0 send \"ferramenta:argumento\""; run_task "$*" 1 ;;
  result) cmd_result "${1:-}" ;;
  status) cmd_status ;;
  watch) cmd_watch ;;
  skills) cmd_skills ;;
  context) cmd_context ;;
  log) cmd_log ;;
  audit) cmd_audit ;;
  doctor) cmd_doctor ;;
  reset) cmd_reset ;;
  "")
      if [ -t 1 ]; then banner "o aquário do Starfish"; echo; fi
      usage ;;
  -h|--help|help) usage ;;
  *) echo "${CR}comando desconhecido:${C0} $c"; echo; usage; exit 1 ;;
esac
