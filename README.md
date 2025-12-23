 # Control Center Automated Deployment Tutorial

Deploy and configure GridGain Control Center via REST API in a fully automated manner, following GitOps/Infrastructure-as-Code patterns.

## Overview

Two equivalent implementations provided:
- **Bash** (`deploy-bash/deploy.sh`) - Uses `bash`, `curl`, `jq`
- **Python** (`deploy-python/deploy.py`) - Uses `httpx`

Both automate: users, teams, clusters, notifications, and alerts.

## Quick Start

### Prerequisites

1. Obtain a Control Center license file
2. Place it at `config/control-center-license.xml`

### Demo (Docker Compose)

Runs everything: Ignite clusters, Control Center, Connector, and deployment script.

```bash
# Create .env file if not created
cp .env.example .env

# Edit .env: CC_ADMIN_EMAIL, CC_ADMIN_PASSWORD
# Ensure config/control-center-license.xml exists
# Export env vars
set -a && source .env && set +a

docker compose up -d 
```

To remove the docker compose use:
```bash
docker compose down -v
```

### Control Center deployment and configuration

Run deployment script against your existing running Control Center:

```bash
# Create .env file if not created
cp .env.example .env

# Edit .env if required: CC_ADMIN_EMAIL, CC_ADMIN_PASSWORD
# Export env vars
set -a && source .env && set +a

# Bash
./deploy-bash/deploy.sh

# Python
pip install -r deploy-python/requirements.txt
python deploy-python/deploy.py
```

## CLI Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview changes without applying |
| `--only COMPONENTS` | Sync specific components only |

```bash
# Examples
./deploy.sh --only users,teams
./deploy.sh --dry-run
```

**Components:** `users`, `teams`, `clusters`, `notifications`, `alerts`

**Dependencies:** `teams` → `users`, `notifications` → `clusters`, `alerts` → `clusters` + `notifications`

## Key Features

- **Idempotent**: Create-or-update pattern, safe to re-run
- **No auto-delete**: Unmanaged resources trigger drift warnings only
- **Drift detection**: Reports resources not in state files

## State Files

State files in `state/` define desired configuration:

| File | Purpose |
|------|---------|
| `users.json` | User accounts (username, password, name, admin flag) |
| `teams.json` | Teams with member lists |
| `clusters.json` | Cluster connections and sharing |
| `notifications.json` | Notification channels (email, etc.) |
| `alerts.json` | Alert rules with conditions and thresholds |

See example files in `state/` directory.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `CC_BASE_URL` | Yes | Control Center URL |
| `CC_ADMIN_EMAIL` | Yes | Admin username |
| `CC_ADMIN_PASSWORD` | Yes | Admin password |
| `CC_HEALTH_TIMEOUT` | No | Health check timeout (default: 300s) |
| `CC_CONNECTOR_TIMEOUT` | No | Connector wait timeout (default: 120s) |

## Resources

- API spec: `openapi/rest-api.yaml`

## License

Copyright (C) GridGain Systems. All Rights Reserved.
