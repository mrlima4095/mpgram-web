#!/bin/sh
# Entrypoint usado no deploy via Coolify.
# Gera config.php/api_values.php a partir das variáveis de ambiente (se ainda não existirem),
# garante as permissões da pasta de sessões e sobe o Apache com uma manutenção
# automática para o MadelineProto.
set -e

cd /var/www/html

php /usr/local/bin/coolify-apply-env-config.php || true

# Pasta de sessões do MadelineProto: precisa existir e ser gravável pelo www-data.
# É aqui que se monta o volume persistente no Coolify.
mkdir -p s
chown -R www-data:www-data s

# O MadelineProto guarda, dentro de cada pasta de sessão, o estado do processo
# "worker" (sockets "ipc"/"callback.ipc" + "ipcState.php" com o PID do worker).
# Como a pasta s/ é um volume persistente, ao recriar o container esses PIDs
# deixam de existir: o MadelineProto acha que o worker está vivo, tenta falar
# com um socket órfão e a requisição fica travada ~60s. Era isso que fazia o
# cliente ficar "carregando pra sempre" depois de cada deploy/restart.
clean_ipc_state() {
    find s -maxdepth 2 \
        \( -name 'ipc' -o -name 'callback.ipc' \
           -o -name 'ipcState.php' -o -name 'ipcState.php.lock' \) \
        -delete 2>/dev/null || true
}

# Limpa o estado de IPC de uma sessão específica.
clean_session_ipc() {
    rm -f "$1/ipc" "$1/callback.ipc" "$1/ipcState.php" "$1/ipcState.php.lock" 2>/dev/null || true
}

# Recicla os workers do MadelineProto e os do Apache. Um worker do Apache que
# travou no meio de uma requisição continua segurando o lock da sessão (e o
# socket com o Telegram) mesmo depois que o worker do MadelineProto morre — e
# aí toda chamada seguinte falha com "session is busy". O master do Apache
# (PID 1) recria os workers sob demanda.
recycle_workers() {
    pkill -TERM -f 'MadelineProto worker' 2>/dev/null || true
    for p in $(pgrep -f '^apache2' 2>/dev/null); do
        [ "$p" = "1" ] || kill -TERM "$p" 2>/dev/null || true
    done
    sleep 3
    pkill -KILL -f 'MadelineProto worker' 2>/dev/null || true
    for p in $(pgrep -f '^apache2' 2>/dev/null); do
        [ "$p" = "1" ] || kill -KILL "$p" 2>/dev/null || true
    done
    clean_ipc_state
}

clean_ipc_state

# Watchdog (a cada 20s). Para cada sessão:
#  1) se o worker do MadelineProto morreu mas sobrou estado de IPC, limpa;
#  2) se o arquivo "lock" da sessão está travado (flock) e não existe worker
#     vivo, é lock órfão de um processo morto: recicla os workers e recria o
#     arquivo de lock. Sem isso, a sessão fica "busy" para sempre e o cliente
#     só volta a funcionar com restart do container.
# A condição só dispara após 2 verificações seguidas, para não atropelar um
# worker que esteja subindo.
(
    while true; do
        sleep 20
        for dir in s/*.madeline; do
            [ -d "$dir" ] || continue
            name=$(basename "$dir")
            marker="/tmp/.mpgram-lock-$name"
            if pgrep -f "MadelineProto worker /var/www/html/$dir" >/dev/null 2>&1; then
                rm -f "$marker"
                continue
            fi
            if [ -e "$dir/ipcState.php" ]; then
                echo "[mpgram] estado de IPC órfão em $name, limpando"
                clean_session_ipc "$dir"
            fi
            if [ -e "$dir/lock" ] && ! flock -n "$dir/lock" true 2>/dev/null; then
                count=$(cat "$marker" 2>/dev/null || echo 0)
                count=$((count + 1))
                echo "$count" > "$marker"
                if [ "$count" -ge 2 ]; then
                    echo "[mpgram] liberando lock órfão de $name"
                    rm -f "$marker"
                    # o dono do lock já morreu; o arquivo pode ser recriado
                    rm -f "$dir/lock"
                    clean_session_ipc "$dir"
                fi
            else
                rm -f "$marker"
            fi
        done
    done
) &

# O README do projeto recomenda reiniciar o serviço PHP pelo menos de hora em
# hora (os workers do MadelineProto são de longa duração e vazam memória).
# O intervalo é configurável (em segundos); 0 desativa.
RESTART_INTERVAL="${MP_WORKER_RESTART_INTERVAL:-3600}"
case "$RESTART_INTERVAL" in
    ''|*[!0-9]*) RESTART_INTERVAL=3600 ;;
esac
if [ "$RESTART_INTERVAL" -gt 0 ]; then
    (
        while true; do
            sleep "$RESTART_INTERVAL"
            echo "[mpgram] reinício periódico dos workers"
            recycle_workers
        done
    ) &
fi

# MadelineProto escreve este log na raiz do site
touch MadelineProto.log 2>/dev/null || true
chown www-data:www-data MadelineProto.log 2>/dev/null || true

echo "[mpgram] iniciando Apache na porta 80"
exec apache2-foreground
