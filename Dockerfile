# MPGram Web — imagem única (Apache + mod_php) pronta para deploy no Coolify.
#
# O repositório já traz a pasta docker/ (nginx + php-fpm + docker-compose legado),
# mas ela depende de volumes_from/links e de bind-mount do código do host, o que
# não encaixa bem no Coolify. Esta imagem roda tudo em um único container que
# escuta na porta 80, e o proxy do Coolify cuida do HTTPS/domínio.
FROM php:8.4-apache

ENV DEBIAN_FRONTEND=noninteractive \
    COMPOSER_ALLOW_SUPERUSER=1 \
    APACHE_DOCUMENT_ROOT=/var/www/html

# Dependências de sistema + extensões exigidas pelo MPGram/MadelineProto.
# As extensões mbstring, xml, fileinfo e iconv já vêm habilitadas na imagem oficial;
# aqui instalamos apenas gd, gmp e ffi (mais procps por causa das chamadas `ps` do app).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgmp-dev \
        libffi-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libfreetype6-dev \
        procps \
        patch \
        unzip \
        git \
        curl \
        ca-certificates \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" gd gmp ffi \
    && a2enmod rewrite headers access_compat \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Composer v2
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Configuração de PHP e Apache
COPY docker/coolify/php.ini /usr/local/etc/php/conf.d/99-mpgram.ini
COPY docker/coolify/apache.conf /etc/apache2/conf-available/mpgram.conf
RUN a2enconf mpgram

# Banco do browscap (nomes de dispositivo mais bonitos nas sessões)
RUN curl -fsSL -o /usr/local/etc/browscap.ini "http://browscap.org/stream?q=Lite_PHP_BrowsCapINI" || true

WORKDIR /var/www/html

# Código da aplicação
COPY . /var/www/html

# MadelineProto + patches do projeto
RUN composer install --no-dev --no-interaction --no-progress --optimize-autoloader \
    && for p in patches/InternalDoc.php.patch patches/Files.php.patch patches/UpdateHandler.php.patch; do \
         patch -p0 -N --batch -i "$p" \
           || echo "AVISO: $p nao aplicou (ja aplicado ou versao diferente do MadelineProto)"; \
       done \
    && mkdir -p s \
    && chown -R www-data:www-data /var/www/html

COPY docker/coolify/entrypoint.sh /usr/local/bin/coolify-entrypoint.sh
COPY docker/coolify/apply-env-config.php /usr/local/bin/coolify-apply-env-config.php
RUN chmod +x /usr/local/bin/coolify-entrypoint.sh

EXPOSE 80
CMD ["/usr/local/bin/coolify-entrypoint.sh"]
