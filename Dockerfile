# syntax=docker/dockerfile:1.7
#
# AskMyDocs (https://github.com/lopadova/AskMyDocs) — Image für Coolify.
#
# Das Image holt den Quellcode beim Build selbst aus dem Upstream-Repository.
# Dockerfile und docker-compose.yml können daher in einem eigenen, kleinen
# Repository liegen — ein Fork von AskMyDocs ist nicht nötig.
#
# Ein Image, drei Rollen (über CONTAINER_ROLE): app | worker | scheduler

ARG PHP_VERSION=8.3
ARG NODE_VERSION=24

# ── Quellcode ────────────────────────────────────────────────────────────────
FROM alpine/git:latest AS source

ARG ASKMYDOCS_REPO=https://github.com/lopadova/AskMyDocs.git
# Branch, Tag oder Commit-SHA. Für reproduzierbare Deployments einen Tag/SHA setzen.
ARG ASKMYDOCS_REF=main

WORKDIR /src
RUN git init -q . \
 && git remote add origin "${ASKMYDOCS_REPO}" \
 && git fetch -q --depth 1 origin "${ASKMYDOCS_REF}" \
 && git checkout -q FETCH_HEAD \
 && git rev-parse HEAD > /src/.source-commit \
 && rm -rf .git .github .idea .claude .superpowers desktop docs-site tests tools

# ── PHP-Basis (Laufzeit + Build der Composer-Abhängigkeiten) ─────────────────
FROM php:${PHP_VERSION}-fpm-bookworm AS base

COPY --from=ghcr.io/mlocati/php-extension-installer:latest /usr/bin/install-php-extensions /usr/local/bin/

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      nginx supervisor curl ca-certificates unzip git procps \
      poppler-utils \
      tesseract-ocr tesseract-ocr-deu tesseract-ocr-eng tesseract-ocr-ita \
 && install-php-extensions \
      pdo_pgsql pgsql intl gd zip bcmath pcntl sockets gmp exif opcache redis \
 && rm -rf /var/lib/apt/lists/* /var/www/html/*

WORKDIR /var/www/html

# ── Composer-Abhängigkeiten ──────────────────────────────────────────────────
FROM base AS vendor

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Optional: GitHub-Token gegen API-Rate-Limits (mehrere Pakete kommen direkt
# aus GitHub-Repositories). Ohne Token fällt Composer auf "git clone" zurück.
ARG GITHUB_TOKEN=""
# "true" installiert zusätzlich die require-dev-Pakete (u. a. laravel/mcp für
# den eingebauten MCP-Server unter /mcp/kb).
ARG INSTALL_DEV_DEPS=false

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1 \
    COMPOSER_MEMORY_LIMIT=-1

COPY --from=source /src /var/www/html

RUN if [ -n "${GITHUB_TOKEN}" ]; then composer config --global github-oauth.github.com "${GITHUB_TOKEN}"; fi \
 && if [ "${INSTALL_DEV_DEPS}" = "true" ]; then DEV_FLAG=""; else DEV_FLAG="--no-dev"; fi \
 && composer install ${DEV_FLAG} --prefer-dist --no-progress --no-scripts --optimize-autoloader \
 && rm -rf /root/.composer /root/.config/composer

# ── Frontend (SPA + Widget) ──────────────────────────────────────────────────
FROM node:${NODE_VERSION}-bookworm-slim AS frontend

WORKDIR /build
COPY --from=source /src /build
RUN npm ci --no-audit --no-fund \
 && npm run build

# ── Laufzeit-Image ───────────────────────────────────────────────────────────
FROM base AS runtime

COPY --from=vendor   /var/www/html              /var/www/html
COPY --from=frontend /build/public/build        /var/www/html/public/build
COPY --from=frontend /build/public/widget       /var/www/html/public/widget

# PHP-Einstellungen
COPY <<'EOF' /usr/local/etc/php/conf.d/zz-askmydocs.ini
memory_limit = 512M
upload_max_filesize = 100M
post_max_size = 110M
max_execution_time = 300
expose_php = Off
variables_order = EGPCS
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 32
opcache.max_accelerated_files = 40000
opcache.validate_timestamps = 0
EOF

# PHP-FPM: Umgebungsvariablen des Containers an PHP durchreichen, Logs nach stderr
COPY <<'EOF' /usr/local/etc/php-fpm.d/zz-askmydocs.conf
[global]
error_log = /proc/self/fd/2

[www]
listen = 127.0.0.1:9000
clear_env = no
catch_workers_output = yes
decorate_workers_output = no
pm = dynamic
pm.max_children = 20
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 6
pm.max_requests = 500
request_terminate_timeout = 310
EOF

# Nginx: lauscht auf 8080, TLS terminiert der Coolify-Proxy (Traefik)
COPY <<'EOF' /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /dev/stderr warn;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    server_tokens off;
    client_max_body_size 110M;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    # Echte Client-IP hinter dem Coolify-Proxy (für Rate-Limits und Audit-Logs)
    set_real_ip_from 10.0.0.0/8;
    set_real_ip_from 172.16.0.0/12;
    set_real_ip_from 192.168.0.0/16;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;

    # Die App konfiguriert keine Trusted Proxies. Damit Laravel HTTPS erkennt
    # (sichere Cookies, https-URLs), wird X-Forwarded-Proto hier übersetzt.
    map $http_x_forwarded_proto $fe_https {
        default "";
        https   on;
    }
    # Port aus dem Host-Header übernehmen (z. B. localhost:8088 im lokalen Test),
    # sonst Standardport passend zum Protokoll.
    map $http_host $host_port {
        default          "";
        "~:(?<hp>\d+)$"  $hp;
    }
    # Debians fastcgi_params übergibt HTTP_HOST ohne Port; hier wieder ergänzen.
    map $host_port $fe_host {
        default          "$host:$host_port";
        ""               $host;
    }
    map "$http_x_forwarded_proto:$host_port" $fe_port {
        default          80;
        "~^https:$"      443;
        "~:(?<fp>\d+)$"  $fp;
    }

    server {
        listen 8080 default_server;
        server_name _;
        root /var/www/html/public;
        index index.php;
        charset utf-8;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location ~* \.(?:css|js|woff2?|ttf|svg|png|jpg|jpeg|gif|ico|webp)$ {
            try_files $uri /index.php?$query_string;
            expires 7d;
            access_log off;
        }

        location ~ \.php$ {
            try_files $uri =404;
            include fastcgi_params;
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
            fastcgi_param DOCUMENT_ROOT $realpath_root;
            fastcgi_param HTTPS $fe_https if_not_empty;
            fastcgi_param SERVER_PORT $fe_port;
            fastcgi_param HTTP_HOST $fe_host;
            fastcgi_read_timeout 310;
            fastcgi_send_timeout 310;
            # Streaming-Antworten (SSE im Chat) nicht puffern
            fastcgi_buffering off;
        }

        location ~ /\.(?!well-known) {
            deny all;
        }
    }
}
EOF

COPY <<'EOF' /etc/supervisor/conf.d/askmydocs.conf
[supervisord]
nodaemon=true
user=root
logfile=/dev/null
logfile_maxbytes=0
pidfile=/run/supervisord.pid

[program:php-fpm]
command=php-fpm -F
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=nginx -g "daemon off;"
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

COPY --chmod=755 <<'EOF' /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -Eeuo pipefail

cd /var/www/html
role="${CONTAINER_ROLE:-app}"

# Beim ersten Start ist das Storage-Volume leer: Verzeichnisstruktur anlegen.
mkdir -p \
    storage/app/public storage/app/kb storage/app/kb-raw storage/app/kb-staging \
    storage/framework/cache/data storage/framework/sessions \
    storage/framework/views storage/framework/testing \
    storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache

if [[ -z "${APP_KEY:-}" || "${APP_KEY}" == "base64:" ]]; then
    echo "FEHLER: APP_KEY ist nicht gesetzt (erwartet: base64:<32 Byte, Base64-kodiert>)." >&2
    exit 1
fi

as_app() { runuser -u www-data -- "$@"; }

as_app php artisan config:cache
as_app php artisan route:cache || as_app php artisan route:clear
# Kein view:cache: ein Vendor-Paket registriert ein nicht vorhandenes
# View-Verzeichnis. Blade kompiliert die Views beim ersten Aufruf.

case "${role}" in
    app)
        as_app php artisan storage:link --force >/dev/null 2>&1 || true

        if [[ "${RUN_MIGRATIONS:-true}" == "true" ]]; then
            as_app php artisan migrate --force --no-interaction
            # Rollen und Berechtigungen; der Seeder ist idempotent.
            as_app php artisan db:seed --class=RbacSeeder --force --no-interaction
        fi

        # Erste Firma + Admin-Konto anlegen (nur solange die Firma fehlt).
        # E-Mail: INITIAL_ADMIN_EMAIL (Standard admin@askmydocs.local).
        # Passwort: COMPANY_ADMIN_PASSWORD (in Coolify per Magic-Variable erzeugt).
        admin_email="${INITIAL_ADMIN_EMAIL:-admin@askmydocs.local}"
        if [[ -n "${COMPANY_ADMIN_PASSWORD:-}" ]]; then
            if as_app php artisan company:create \
                --company="${INITIAL_COMPANY_NAME:-AskMyDocs}" \
                --email="${admin_email}" \
                --role="${INITIAL_ADMIN_ROLE:-super-admin}" \
                --no-interaction; then
                echo "Admin-Konto angelegt: ${admin_email} (Passwort: Variable COMPANY_ADMIN_PASSWORD)"
            else
                echo "Hinweis: company:create übersprungen (Firma/Konto existiert bereits)."
            fi
        else
            echo "Hinweis: kein Admin-Konto angelegt (COMPANY_ADMIN_PASSWORD fehlt)."
        fi

        exec supervisord -c /etc/supervisor/supervisord.conf
        ;;
    worker)
        exec runuser -u www-data -- php artisan queue:work \
            --queue="${WORKER_QUEUES:-agent,default,kb-ingest,connectors}" \
            --sleep=2 --max-time=3600 --timeout="${WORKER_TIMEOUT:-3700}" --no-interaction
        ;;
    scheduler)
        exec runuser -u www-data -- php artisan schedule:work --no-interaction
        ;;
    *)
        exec "$@"
        ;;
esac
EOF

RUN mkdir -p storage/app/public storage/framework/cache/data storage/framework/sessions \
             storage/framework/views storage/logs bootstrap/cache \
 && php artisan package:discover --ansi \
 # Frontend-Assets der Admin-Panels und Connectoren nach public/vendor publizieren
 && for tag in $(grep -rhoE "'[a-z0-9-]+-assets'" vendor/padosoft | tr -d "'" | sort -u); do \
      php artisan vendor:publish --tag="${tag}" --force --no-interaction || true; \
    done \
 && chown -R www-data:www-data storage bootstrap/cache public

ENV APP_ENV=production \
    APP_DEBUG=false \
    LOG_CHANNEL=stderr \
    CONTAINER_ROLE=app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
    CMD if [ "${CONTAINER_ROLE}" = "app" ]; then curl -fsS http://127.0.0.1:8080/up >/dev/null || exit 1; else pgrep -f "artisan" >/dev/null || exit 1; fi

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
