#!/usr/bin/env bash
# Starfish - ferramentas `sh` e `run` do braco operador.
#   bash tools/sandbox.sh init   -> cria a pasta de trabalho
#   bash tools/sandbox.sh sh     -> TERMINAL REAL (tools/term.py): qualquer comando bash, sessao persistente
#   bash tools/sandbox.sh run    -> executa um arquivo de starfish_workspace/Starfish_Work/ (py e sh preferidos)
# Argumento em starfish_workspace/tool_arg.txt. Saida termina sempre com "[exit N]".
# ISOLAMENTO: `sh` e `run` rodam dentro de um bwrap: so Starfish_Work/ e gravavel e o resto do disco
# nao existe la dentro (veja tools/term.py). Sem bwrap, recusam rodar. STARFISH_JAIL=off desliga.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
WS="$ROOT/starfish_workspace"; SB="$WS/Starfish_Work"; ARGFILE="$WS/tool_arg.txt"
TIMEOUT="${STARFISH_CMD_TIMEOUT:-60}"; MAXOUT=20000
mkdir -p "$SB"
MODE="$1"
[ "$MODE" = "init" ] && { echo "ok"; exit 0; }

if [ "$MODE" = "sh" ]; then
  exec python3 "$HERE/term.py"
fi

if [ "$MODE" = "run" ]; then
  F="$(head -n 1 "$ARGFILE" 2>/dev/null | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//')"
  if ! printf '%s' "$F" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,59}$'; then
    echo "ERROR: nome de arquivo invalido: '$F'"; exit 0
  fi
  [ -f "$SB/$F" ] || { echo "ERROR: arquivo nao existe em Starfish_Work/: $F"; exit 0; }
  case "$F" in
    *.py)  RUN=(python3 -u "$F") ;;
    *.sh)  RUN=(bash "$F") ;;
    *.js)  RUN=(node "$F") ;;
    *.c)   RUN=(bash -c 'gcc -o prog_out "$1" -lm && ./prog_out' _ "$F") ;;
    *.cpp) RUN=(bash -c 'g++ -std=c++17 -o prog_out "$1" && ./prog_out' _ "$F") ;;
    *) echo "ERROR: extensao nao suportada (use .py ou .sh; tambem .js .c .cpp)"; exit 0 ;;
  esac
  # passa pelo MESMO terminal isolado (bwrap): so enxerga Starfish_Work/
  CMD="cd $(printf '%q' "$SB") && "; for w in "${RUN[@]}"; do CMD+="$(printf '%q' "$w") "; done
  exec python3 "$HERE/term.py" -c "$CMD"
fi
echo "ERROR: modo desconhecido"
