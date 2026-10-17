#!/bin/sh
# Entrypoint usado no deploy via Coolify.
# Gera config.php/api_values.php a partir das variáveis de ambiente (se ainda não existirem),
# garante as permissões da pasta de sessões e sobe o Apache.
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
# Limpar esse estado no boot força a criação de um worker novo.
clean_ipc_state() {
    find s -maxdepth 2 \
        \( -name 'ipc' -o -name 'callback.ipc' \
           -o -name 'ipcState.php' -o -name 'ipcState.php.lock' \) \
        -delete 2>/dev/null || true
}

clean_ipc_state

# Watchdog: se um worker morrer em tempo de execução (crash/restart do Apache),
# o estado de IPC fica órfão e a sessão trava. A cada minuto, remove o estado
# de IPC de sessões sem worker vivo.
(
    while true; do
        sleep 60
        now=$(date +%s)
        for st in s/*.madeline/ipcState.php; do
            [ -e "$st" ] || continue
            dir=$(dirname "$st")
            mtime=$(date -r "$st" +%s 2>/dev/null || echo "$now")
            # estado recente: o worker pode estar subindo, não mexer
            [ $((now - mtime)) -lt 300 ] && continue
            if ! pgrep -f "MadelineProto worker /var/www/html/$dir" >/dev/null 2>&1; then
                echo "[mpgram] estado IPC órfão em $dir, limpando"
                rm -f "$dir/ipc" "$dir/callback.ipc" \
                      "$dir/ipcState.php" "$dir/ipcState.php.lock"
            fi
        done
    done
) &

# O README do projeto recomenda reiniciar o serviço PHP pelo menos de hora em
# hora (os workers do MadelineProto são de longa duração e vazam memória).
# Aqui matamos só os "MadelineProto worker"; o Apache recria sob demanda.
RESTART_INTERVAL="${MP_WORKER_RESTART_INTERVAL:-3600}"
case "$RESTART_INTERVAL" in
    ''|*[!0-9]*) RESTART_INTERVAL=3600 ;;
esac
if [ "$RESTART_INTERVAL" -gt 0 ]; then
    (
        while true; do
            sleep "$RESTART_INTERVAL"
            echo "[mpgram] reinício periódico dos workers do MadelineProto"
            pkill -TERM -f 'MadelineProto worker' 2>/dev/null || true
            sleep 3
            pkill -KILL -f 'MadelineProto worker' 2>/dev/null || true
            clean_ipc_state
        done
    ) &
fi

# MadelineProto escreve este log na raiz do site
touch MadelineProto.log 2>/dev/null || true
chown www-data:www-data MadelineProto.log 2>/dev/null || true

echo "[mpgram] iniciando Apache na porta 80"
exec apache2-foreground
