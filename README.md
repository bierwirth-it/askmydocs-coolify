# AskMyDocs für Coolify

Deployment von [AskMyDocs](https://github.com/lopadova/AskMyDocs) (Self-hosted AI Knowledge Hub, Laravel + PostgreSQL/pgvector) auf Coolify.

| Datei | Zweck |
|---|---|
| `Dockerfile` | Baut das Image (holt den Quellcode selbst von GitHub, Branch/Tag über `ASKMYDOCS_REF`) |
| `docker-compose.yml` | Variante **mit Build in Coolify** (Build Pack „Docker Compose“ aus diesem Repo) |
| `coolify-template.yml` | Variante **ohne Build**: Coolify-Service-Template mit fertigem Image aus der GitHub Container Registry |
| `.github/workflows/build-image.yml` | Baut das Image automatisch und veröffentlicht es als `ghcr.io/<owner>/askmydocs` |
| `docker-compose.local.yml`, `.env.local` | Nur für lokale Tests mit Docker Desktop |

## Was automatisch passiert

- **Passwörter und Schlüssel** erzeugt Coolify über Magic-Variablen: `SERVICE_PASSWORD_POSTGRES`, `SERVICE_PASSWORD_REDIS`, `SERVICE_REALBASE64_APPKEY` (→ `APP_KEY`).
- **URL und Domain** kommen aus `SERVICE_URL_APP` / `SERVICE_FQDN_APP` (Domain am Service `app` setzen).
- **Migrationen und Rollen** laufen beim Start des `app`-Containers (`RUN_MIGRATIONS=true`).
- **Erstes Admin-Konto** wird angelegt, wenn `INITIAL_ADMIN_EMAIL` und `COMPANY_ADMIN_PASSWORD` gesetzt sind.
- **Host-Zertifikate**: Das CA-Bundle des Coolify-Hosts (`/etc/ssl/certs/ca-certificates.crt`) wird per Bind-Mount in die App-Container gelegt. Interne CAs so einbinden:

  ```bash
  sudo cp interne-ca.crt /usr/local/share/ca-certificates/
  sudo update-ca-certificates
  ```

  Danach die Container neu starten – PHP und cURL vertrauen dann internen Diensten wie n8n, Ollama oder Open WebUI. Anderer Pfad: Variable `HOST_CA_BUNDLE` setzen.

## Variante A: Template mit fertigem Image (empfohlen)

1. Dieses Verzeichnis als GitHub-Repository anlegen und pushen. Der Workflow baut das Image und veröffentlicht es unter `ghcr.io/<owner>/askmydocs:latest` (Paket im Repo auf „public“ stellen oder in Coolify Registry-Zugangsdaten hinterlegen).
2. In `coolify-template.yml` den Platzhalter `OWNER` durch den GitHub-Namen ersetzen (oder in Coolify `ASKMYDOCS_IMAGE` setzen).
3. Coolify → Projekt → **+ New** → **Docker Compose Empty** → Inhalt von `coolify-template.yml` einfügen.
4. Domain am Service `app` eintragen, Variablen setzen (siehe unten), **Deploy**.

Um das Template dauerhaft in der Service-Liste zu haben, die Datei auf dem Coolify-Server nach `/data/coolify/templates/compose/askmydocs.yaml` kopieren (kein Build nötig, da das Image fertig ist).

## Variante B: Build direkt in Coolify

1. Repository in Coolify als neue Ressource anlegen, Build Pack **Docker Compose**, Datei `docker-compose.yml`.
2. Domain am Service `app` eintragen, Variablen setzen, **Deploy**. Der erste Build dauert einige Minuten.

## Variablen in Coolify

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `OPENROUTER_API_KEY` / `OPENAI_API_KEY` | ja (mind. einer) | KI-Provider; Standard: Chat über OpenRouter, Embeddings über OpenAI |
| `AI_PROVIDER`, `AI_EMBEDDINGS_PROVIDER` | nein | `openai`, `anthropic`, `gemini`, `openrouter`, `regolo` |
| `INITIAL_ADMIN_EMAIL`, `COMPANY_ADMIN_PASSWORD` | empfohlen | Erstes Admin-Konto (Passwort mind. 8 Zeichen) |
| `INITIAL_COMPANY_NAME` | nein | Name des ersten Mandanten |
| `APP_TIMEZONE`, `APP_LOCALE` | nein | Standard `Europe/Berlin`, `en` |
| `HOST_CA_BUNDLE` | nein | Pfad zum CA-Bundle des Hosts |
| `ASKMYDOCS_REF` (nur Variante B) | nein | Branch, Tag oder Commit von AskMyDocs |
| `INSTALL_DEV_DEPS` (nur Variante B) | nein | `true` installiert `laravel/mcp` für den MCP-Endpunkt `/mcp/kb` |

## Dienste

`app` (Nginx + PHP-FPM, Port 8080) · `worker` (Queues `agent`, `default`, `kb-ingest`, `connectors`) · `scheduler` · `postgres` (pgvector/pg17) · `redis`

## Lokaler Test

```powershell
docker compose -p askmydocs-local --env-file .env.local -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

Danach http://localhost:8088 (Zugangsdaten in `.env.local`). `.env.local` nicht committen, sobald echte API-Keys darin stehen.
