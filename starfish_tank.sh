#!/usr/bin/env bash
# starfish_tank.sh — controle do Starfish por linha de comando (subir, perguntar, acompanhar).
#
#   ./starfish_tank.sh start                 sobe o Starfish em segundo plano
#   ./starfish_tank.sh stop | restart
#   ./starfish_tank.sh ask   "o que é uma estrela-do-mar?"     pergunta rápida (1 chamada)
#   ./starfish_tank.sh gen   "explique a anatomia ..."         resposta longa, revisada em partes
#   ./starfish_tank.sh agent "leia notes.txt e resuma"         agente com ferramentas
#   ./starfish_tank.sh echo|read|write|http "argumento"
#   ./starfish_tank.sh skill list | show NOME | novo "tema" | NOME "tarefa"
#   ./starfish_tank.sh mem list | count | find "palavra" | add "regra"
#   ./starfish_tank.sh status | watch | skills | context | log
#   ./starfish_tank.sh result ID             mostra o resultado de uma task já enviada
#   ./starfish_tank.sh send "ferramenta:argumento"             envia sem esperar (--no-wait)
#   ./starfish_tank.sh reset                 apaga contexto, skills e nível (pede confirmação)
#
# Variáveis opcionais:
#   STARFISH_DIR      pasta do projeto (onde está STARFISH.cnr). Padrão: pasta deste script
#   CNR               executável do interpretador CnR. Padrão: CnR (ou cnr, se achar)
#   STARFISH_URL      padrão http://localhost:7070
#   STARFISH_TIMEOUT  segundos de espera por task (padrão 3600)
# Precisa de: bash, curl, python3.

set -u
DIR="${STARFISH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
URL="${STARFISH_URL:-http://localhost:7070}"
TIMEOUT="${STARFISH_TIMEOUT:-3600}"
PIDFILE="$DIR/.starfish.pid"
OUTFILE="$DIR/starfish.out"

if [ -n "${CNR:-}" ]; then BIN="$CNR"
elif command -v CnR >/dev/null 2>&1; then BIN="CnR"
elif command -v cnr >/dev/null 2>&1; then BIN="cnr"
else BIN="CnR"; fi

die() { echo "erro: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "preciso do '$1' instalado"; }
need curl; need python3

is_up() { curl -s -m 2 "$URL/status" >/dev/null 2>&1; }

need_up() {
  is_up || die "o Starfish não está respondendo em $URL. Rode: $0 start"
}

# lê um campo de um JSON (stdin): jget campo
jget() { python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); v=d.get(sys.argv[1],"")
    print(v if not isinstance(v,(dict,list)) else json.dumps(v,ensure_ascii=False))
except Exception: print("")' "$1"; }

cmd_start() {
  if is_up; then echo "o Starfish já está rodando em $URL"; return 0; fi
  [ -f "$DIR/STARFISH.cnr" ] || die "não achei STARFISH.cnr em $DIR (use STARFISH_DIR)"
  command -v "$BIN" >/dev/null 2>&1 || [ -x "$BIN" ] || die "não achei o interpretador '$BIN' (use CNR=/caminho/CnR)"
  mkdir -p "$DIR/starfish_workspace" "$DIR/models"
  ( cd "$DIR" && nohup "$BIN" STARFISH.cnr >"$OUTFILE" 2>&1 & echo $! >"$PIDFILE" )
  echo -n "subindo"
  for _ in $(seq 1 600); do   # até 10 min: carregar o modelo pode demorar
    if is_up; then echo; echo "pronto: $URL (log: $DIR/starfish.log)"; return 0; fi
    if [ -f "$PIDFILE" ] && ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo; echo "o Starfish encerrou ao subir. Saída:"; tail -n 15 "$OUTFILE"; return 1
    fi
    echo -n "."; sleep 1
  done
  echo; die "demorou demais para subir; veja $OUTFILE e $DIR/llama-server.log"
}

cmd_stop() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE" && echo "Starfish parado."
  else
    echo "não achei um Starfish iniciado por este script (pidfile)."
    echo "se ele roda em outro terminal, use Ctrl+C lá."
  fi
}

# envia uma task e imprime o id
post_task() {
  python3 - "$URL" "$1" <<'PY'
import sys, json, urllib.request
url, task = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url + "/tasks", data=json.dumps({"task": task}).encode(), method="POST")
try:
    print(json.load(urllib.request.urlopen(req, timeout=20))["taskId"])
except Exception as e:
    sys.exit("falha ao enviar: %s" % e)
PY
}

show_result() {
  local R="$1"
  python3 -c 'import sys,json
d=json.load(sys.stdin)
ev=[e for e in d.get("events","").split("\n") if e.strip()]
print("STATUS:", d["status"])
if ev:
    print("\n--- EVENTOS (o que os braços fizeram) ---")
    for e in ev: print(" *", e)
print("\n--- RESULTADO ---")
print(d.get("result",""))' <<<"$R"
}

# envia e espera, mostrando o progresso ao vivo
run_task() {
  local task="$1" nowait="${2:-0}"
  need_up
  local id; id=$(post_task "$task") || exit 1
  echo "task $id enviada: $task"
  [ "$nowait" = "1" ] && { echo "veja depois: $0 result $id"; return 0; }
  local start last="" R S P now
  start=$(date +%s)
  while true; do
    R=$(curl -s -m 10 "$URL/tasks/$id") || R=""
    S=$(jget status <<<"$R")
    if [ "$S" = "done" ] || [ "$S" = "failed" ]; then break; fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$TIMEOUT" ]; then
      echo; echo "passou de ${TIMEOUT}s; a task continua no Starfish. Veja: $0 result $id"; return 2
    fi
    P=$(curl -s -m 5 "$URL/status" | jget progress)
    if [ -n "$P" ] && [ "$P" != "$last" ]; then
      printf '  [%ss] %s\n' "$((now - start))" "$P"; last="$P"
    fi
    sleep 2
  done
  echo
  show_result "$R"
  echo; echo "(levou $(( $(date +%s) - start ))s)"
}

cmd_result() {
  need_up
  [ -n "${1:-}" ] || die "uso: $0 result ID"
  show_result "$(curl -s "$URL/tasks/$1")"
}

cmd_status() {
  need_up
  curl -s "$URL/status" | python3 -c 'import sys,json
d=json.load(sys.stdin)
print("nível    :", d.get("level"))
print("resumo   :", d.get("summary"))
print("processadas:", d.get("processed"), "| na fila:", d.get("pending"), "| rodando: task", d.get("running"))
print("agora    :", d.get("progress"))
print("\nbraços (R<n><papel><+vivo/x morto> g=geração):")
for a in d.get("rays","").split(") "):
    if a.strip(): print("  ", a.strip() + (")" if not a.strip().endswith(")") else ""))'
}

cmd_watch() {
  need_up
  echo "acompanhando (Ctrl+C para sair)"
  local last=""
  while true; do
    P=$(curl -s -m 5 "$URL/status" | jget progress)
    if [ "$P" != "$last" ]; then printf '%s  %s\n' "$(date +%H:%M:%S)" "$P"; last="$P"; fi
    sleep 1
  done
}

cmd_skills()  { need_up; curl -s "$URL/skills"  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("skills",""))'; }
cmd_context() { need_up; curl -s "$URL/context" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("lessons",""))'; }
cmd_log()     { [ -f "$DIR/starfish.log" ] || die "ainda não existe $DIR/starfish.log"; tail -n 40 -f "$DIR/starfish.log"; }

cmd_reset() {
  echo "Isto apaga contexto (lições), skills, nível/XP e notas em $DIR/starfish_workspace e o starfish.log."
  read -r -p "Digite 'sim' para confirmar: " ans
  [ "$ans" = "sim" ] || { echo "cancelado."; return 1; }
  if is_up; then echo "parando o Starfish antes..."; cmd_stop; sleep 1; fi
  rm -f "$DIR"/starfish_workspace/context.txt "$DIR"/starfish_workspace/skills.txt \
        "$DIR"/starfish_workspace/estado.txt "$DIR"/starfish_workspace/notes.txt \
        "$DIR"/starfish_workspace/progresso.txt "$DIR"/starfish.log
  echo "pronto. Rode: $0 start"
}

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

c="${1:-}"; [ $# -gt 0 ] && shift
case "$c" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_stop; sleep 1; cmd_start ;;
  ask|gen|agent|echo|read|write|http)
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
  reset) cmd_reset ;;
  ""|-h|--help|help) usage ;;
  *) echo "comando desconhecido: $c"; echo; usage; exit 1 ;;
esac