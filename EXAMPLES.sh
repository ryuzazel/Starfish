# setup / health
./starfish_tank.sh doctor
./starfish_tank.sh start
./starfish_tank.sh status

# basic tools
./starfish_tank.sh echo "test"
./starfish_tank.sh save "note.txt|hello starfish"
./starfish_tank.sh read Starfish_Work/note.txt
./starfish_tank.sh write "quick note"
./starfish_tank.sh http http://localhost:7070/status

# ask / gen
./starfish_tank.sh ask "what is an ambulacrum?"
./starfish_tank.sh gen "write 3 short paragraphs about coral reefs"

# search / web / research
./starfish_tank.sh search "starfish anatomy"
./starfish_tank.sh search --debug "sea star regeneration"
./starfish_tank.sh web https://en.wikipedia.org/wiki/Starfish
./starfish_tank.sh research "how does a starfish regenerate an arm?"

# terminal
./starfish_tank.sh term "uname -a"
./starfish_tank.sh term "pwd; ls -la"
./starfish_tank.sh term "python3 --version; gcc --version | head -1"
./starfish_tank.sh sh "echo hello from the operator"
echo 'print(6*7)' > starfish_workspace/Starfish_Work/t.py && ./starfish_tank.sh run t.py
printf '#!/bin/bash\necho from bash\n' > starfish_workspace/Starfish_Work/t.sh && ./starfish_tank.sh run t.sh
./starfish_tank.sh audit

# isolation checks
./starfish_tank.sh term "cat /home/$USER/.bashrc"
./starfish_tank.sh term "ls -a /home/$USER"
./starfish_tank.sh term "touch /etc/x"
./starfish_tank.sh term "env"
./starfish_tank.sh term "cd /; pwd"
./starfish_tank.sh term "pwd"
./starfish_tank.sh term "sudo ls"
./starfish_tank.sh term "curl -sI https://example.com | head -1"

# code
./starfish_tank.sh code "print the first 10 primes"
./starfish_tank.sh code "write a script that prints the fibonacci numbers up to 100 using only the standard library"

# agent
./starfish_tank.sh agent "run uname -a and save the output in sys.txt, then cat the file"
./starfish_tank.sh agent "use curl on https://economia.awesomeapi.com.br/json/last/USD-BRL, take the bid field and save it in dolar.txt"
./starfish_tank.sh agent "create a python script that lists the primes up to 100 using only the standard library, run it and save the output in primos.txt"
./starfish_tank.sh agent "search the web for what an ambulacrum is and answer in one sentence"
./starfish_tank.sh term "cat sys.txt dolar.txt primos.txt"

# tasks
./starfish_tank.sh send "echo:ping"
./starfish_tank.sh result
./starfish_tank.sh result 1

# memory
./starfish_tank.sh mem add "in python, use only the standard library"
./starfish_tank.sh mem list
./starfish_tank.sh mem count
./starfish_tank.sh mem find "python"

# skills
./starfish_tank.sh skills
./starfish_tank.sh skill list
./starfish_tank.sh skill show check-math
./starfish_tank.sh skill novo "review python code"
./starfish_tank.sh skill check-math "what is 17*23?"

# state / logs
./starfish_tank.sh context
./starfish_tank.sh watch
./starfish_tank.sh log

# chat (interactive)
./starfish_tank.sh chat
#   inside chat try:
#   !ls -la
#   /sh echo hi
#   /code print the first 10 primes
#   /research what is a water vascular system?
#   /search starfish
#   /web https://en.wikipedia.org/wiki/Starfish
#   /ask what is a blastema?
#   /gen two paragraphs about tide pools
#   /mem list
#   /skill list

# lifecycle
./starfish_tank.sh restart
./starfish_tank.sh stop