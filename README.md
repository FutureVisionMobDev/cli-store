# cli-store (JKSTORE)

Self-hosted app catalog: upload installers (or link GitHub Releases / CDN), users install with one CLI command.

## Features

- Admin UI — publish `.exe` / `.msi` / `.pkg` / `.dmg` / `.zip`
- **Upload to server** or **external URL** (GitHub release asset, etc.) with SHA256
- Chunked uploads for large files
- Windows + macOS CLI menu
- Zip packages: auto-extract + launch main executable
- Manifest at `/apps.json` with checksum verification before install

## Local run

```bash
npm install
export ADMIN_USER=admin
export ADMIN_PASS=changeme
export PORT=3000
node server.js
```

- Admin: http://localhost:3000/admin
- Manifest: http://localhost:3000/apps.json

**Change `ADMIN_PASS` before any public deploy.** Defaults are for local/dev only.

## CLI

Windows (PowerShell) — interactive menu:

```powershell
irm https://YOUR-DOMAIN | iex
```

Or install one app:

```powershell
irm https://YOUR-DOMAIN/install.ps1 | iex; Install -App <slug>
```

macOS:

```bash
curl -fsSL https://YOUR-DOMAIN | bash
# or
curl -fsSL https://YOUR-DOMAIN/install.sh | bash -s <slug>
```

Edit `$DefaultStore` / `DEFAULT_STORE` in the install scripts, or pass `-Store` / `STORE=...`.

## Docker

```bash
docker compose up -d --build
# or
docker build -t cli-store .
docker run --rm -p 3000:3000 \
  -e ADMIN_USER=admin -e ADMIN_PASS='your-strong-password' \
  -v cli_store_uploads:/app/uploads \
  -v cli_store_data:/app/data \
  cli-store
```

Volumes: `/app/uploads` (binaries), `/app/data` (SQLite).

Env: `PORT`, `ADMIN_USER`, `ADMIN_PASS`.
