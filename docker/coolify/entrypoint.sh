#!/bin/sh
# Entrypoint usado no deploy via Coolify.
# Gera config.php/api_values.php a partir das variáveis de ambiente (se ainda não existirem)
# e garante as permissões da pasta de sessões antes de subir o Apache.
set -e

cd /var/www/html

php /usr/local/bin/coolify-apply-env-config.php || true

# Pasta de sessões do MadelineProto: precisa existir e ser gravável pelo www-data.
# É aqui que se monta o volume persistente no Coolify.
mkdir -p s
chown -R www-data:www-data s

# MadelineProto escreve este log na raiz do site
touch MadelineProto.log 2>/dev/null || true
chown www-data:www-data MadelineProto.log 2>/dev/null || true

echo "[mpgram] iniciando Apache na porta 80"
exec apache2-foreground
