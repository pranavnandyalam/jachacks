# JacHacks vulnerable websites

Three deliberately vulnerable websites with usable frontends and synthetic data. Each has its own source, Dockerfile, and persistent data volume.

## Run

With Docker Desktop running Linux containers and Docker Compose v2 installed:

```sh
docker compose up --build -d
```

| Website | URL | Backend |
|---|---|---|
| Task board | http://127.0.0.1:8101 | TypeScript / Express / SQLite |
| Support portal | http://127.0.0.1:8102 | Python / FastAPI / SQLite |
| Deployment dashboard | http://127.0.0.1:8103 | Go / standard HTTP library |

On every website, ordinary users can sign in with `alice` / `alice-demo-pass` or `bob` / `bob-demo-pass`.

Administrator username is `admin`. Default passwords are `task-admin-demo-pass` for the task board, `support-admin-demo-pass` for the support portal, and `demo-deploy-admin-7c41` for the deployment dashboard. All credentials are synthetic. The task board and support portal accept overrides through `TASK_ADMIN_PASSWORD` and `SUPPORT_ADMIN_PASSWORD`; the dashboard intentionally uses its hardcoded credential instead of the injected `DEPLOY_ADMIN_PASSWORD`.

## Websites

- **Task board:** sign in, create and view tasks, and manage users as an administrator. Deliberate flaws: cross-user task access (IDOR/BOLA) and missing role checks on user updates (BFLA).
- **Support portal:** submit tickets, export tickets, and view account details. Deliberate flaws: unauthenticated ticket export and an internal service token in the account response.
- **Deployment dashboard:** view releases and simulate deployments as an administrator. Deliberate flaws: exposed debug configuration and a hardcoded administrator credential. Deployments only create local records.

Source lives under `apps/task-board`, `apps/support-portal`, and `apps/deployment-dashboard`. Sessions are held in memory; sign in again after restarting. Business data persists in Docker volumes.

## Common commands

```sh
# Rebuild one website after editing its source
docker compose up --build -d task-board

# Stop websites, retaining their data
docker compose down

# Delete stored data, then recreate the seeded websites
docker compose down --volumes
docker compose up --build -d
```

Published ports bind to loopback only. Keep these deliberately vulnerable websites local and use only synthetic data.
