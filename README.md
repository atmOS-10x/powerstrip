<p align="center"><img src="brand/banner.png" alt="powerstrip: Electric for every git worktree" width="800"></p>

# powerstrip

**One [Electric](https://github.com/electric-sql/electric) for every git worktree: one instance syncs every database on your Postgres server.** Give each worktree, branch or preview its own database and plug them all into one shared instance: no Electric container per worktree, and no replication slot left behind by a worktree you stopped.

It's stock Electric 1.7.9 plus one opt-in mode. With `ELECTRIC_MULTI_DATABASE` unset, it behaves exactly like upstream.

```sh
docker run -p 3000:3000 \
  -e DATABASE_URL=postgresql://electric:secret@postgres:5432/app \
  -e ELECTRIC_SECRET=... \
  -e ELECTRIC_MULTI_DATABASE=true \
  ghcr.io/atmos-10x/powerstrip:latest
```

```
GET /v1/shape?table=items               → database "app" (DATABASE_URL), as always
GET /db/app_feature_x/v1/shape?table=…  → database "app_feature_x" on the same server
GET /db/app_pr_123/v1/shape?table=…     → database "app_pr_123"
```

A worktree only changes its Electric URL, for example `http://localhost:3000/db/app_feature_x`. Every Electric client and proxy that appends `/v1/shape` to a base URL works unchanged.

## How it works

- **Lazy start.** The first request for `/db/<name>` starts a stack for that database inside the same process. It uses the credentials, host and options of `DATABASE_URL` (and `ELECTRIC_POOLED_DATABASE_URL`) with only the database name swapped, and holds that first request until the stack is replicating.
- **Temporary slots.** Each stack replicates through a temporary slot with a random name. When a stack stops, Postgres drops its slot, so a forgotten worktree never pins WAL.
- **Idle stop.** A database with no requests for `ELECTRIC_MULTI_DATABASE_IDLE_TIMEOUT` stops. The next request starts it again with fresh shape logs, and clients holding older shapes get Electric's usual `409 must-refetch`.
- **Isolation.** Each database gets its own stack (replication client, shape cache, storage directory, connection pool), so shapes never mix across databases. The same `ELECTRIC_SECRET` guards every database.
- **Cheap.** Extra databases share the runtime. In our measurements three databases used 330–350 MB in one process; three stock Electric containers use about 300 MB each.

## Configuration

| Variable | Default | |
|---|---|---|
| `ELECTRIC_MULTI_DATABASE` | `false` | Turns the mode on. |
| `ELECTRIC_MULTI_DATABASE_PATTERN` | any name | Regular expression the whole database name must match, e.g. `app_.*`. Anything else answers 404. |
| `ELECTRIC_MULTI_DATABASE_IDLE_TIMEOUT` | `30m` | Stop a database's stack after this long without requests (`ms`, `s` or `m`). |
| `ELECTRIC_MULTI_DATABASE_POOL_SIZE` | `5` | Query pool per extra database, so many databases fit in `max_connections`. |

Every upstream variable keeps its meaning and applies to the default database.

`DELETE /db/<name>?secret=…` stops a database's stack and drops its slot right away. Call it before `DROP DATABASE`: Postgres refuses to drop a database with an active replication slot.

Each database needs what Electric always needs: a role with `REPLICATION` that may connect to it, and, with `ELECTRIC_MANUAL_TABLE_PUBLISHING`, the publication (`electric_publication_default`) in that database.

## Example: one stack for all worktrees

```yaml
# compose.yaml, started once per machine
services:
  postgres:
    image: postgres:17-alpine
    command: ["postgres", "-c", "wal_level=logical", "-c", "max_replication_slots=40",
              "-c", "max_wal_senders=40", "-c", "max_connections=400"]
  electric:
    image: ghcr.io/atmos-10x/powerstrip:latest
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres:5432/app?sslmode=disable
      ELECTRIC_MULTI_DATABASE: "true"
      ELECTRIC_MULTI_DATABASE_PATTERN: app_.*
    ports: ["127.0.0.1:3000:3000"]
```

```sh
# in a new worktree
createdb app_$(basename "$PWD")
export ELECTRIC_URL=http://localhost:3000/db/app_$(basename "$PWD")
```

## Scope

It's meant for development and previews, not production multi-tenancy. In production, run upstream Electric or [Electric Cloud](https://electric-sql.com/product/cloud). The change is small and self-contained: [`multi_database.ex`](packages/sync-service/lib/electric/multi_database.ex), [`multi_database_router.ex`](packages/sync-service/lib/electric/plug/multi_database_router.ex) and a few lines of wiring. [`scripts/multi_database_test.sh`](packages/sync-service/scripts/multi_database_test.sh) checks it end to end against a real Postgres.

## License and credit

Electric is by [ElectricSQL](https://electric-sql.com) and licensed under [Apache 2.0](packages/sync-service/LICENSE), and so is this fork. Files changed from upstream say so in their first line. Upstream's README follows below.

powerstrip is an independent fork and isn't affiliated with or endorsed by ElectricSQL; "Electric" is their name.

---

<p align="center">
  <a href="https://electric-sql.com" target="_blank">
    <picture>
      <source media="(prefers-color-scheme: dark)"
          srcset="https://raw.githubusercontent.com/electric-sql/meta/main/identity/ElectricSQL-logo-next.svg"
      />
      <source media="(prefers-color-scheme: light)"
          srcset="https://raw.githubusercontent.com/electric-sql/meta/main/identity/ElectricSQL-logo-black.svg"
      />
      <img alt="ElectricSQL logo"
          src="https://raw.githubusercontent.com/electric-sql/meta/main/identity/ElectricSQL-logo-black.svg"
      />
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://github.com/electric-sql/electric/actions"><img src="https://github.com/electric-sql/electric/actions/workflows/elixir_tests.yml/badge.svg"></a>
  <a href="https://github.com/electric-sql/electric/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-green" alt="License - Apache 2.0"></a>
  <a href="https://electric-sql.com/blog/2025/03/17/electricsql-1.0-released"><img src="https://img.shields.io/badge/status-1.0-green" alt="Status - Beta"></a>
  <a href="https://discord.electric-sql.com"><img src="https://img.shields.io/discord/933657521581858818?color=5969EA&label=discord" alt="Chat - Discord"></a>
  <a href="https://x.com/ElectricSQL" target="_blank"><img src="https://img.shields.io/twitter/follow/ElectricSQL.svg?style=social&label=Follow @ElectricSQL"></a>
</p>

# Electric <!-- omit in toc -->

Real-time sync for Postgres.

**Table of Contents:**

- [Quick links](#quick-links)
- [What is Electric?](#what-is-electric)
- [Getting Started](#getting-started)
- [HTTP API Docs](#http-api-docs)
- [Phoenix LiveDashboard](#phoenix-livedashboard)
- [Developing Electric](#developing-electric)
  - [Mac setup](#mac-setup)
- [Contributing](#contributing)
- [Support](#support)

## Quick links

- [Quickstart](https://electric-sql.com/docs/quickstart)
- [Website](https://electric-sql.com)
- [About](https://electric-sql.com/about)
- [Docs](https://electric-sql.com/docs)
- [Demos](https://electric-sql.com/demos) (also see the [`./examples` folder](./examples))

## What is Electric?

Sync is the magic ingredient behind fast, modern software. From apps like Figma and Linear to AI agents running on live local data.

Electric is a Postgres sync engine. It solves the hard problems of sync for you, including partial replication, fan-out, and data delivery. So you can build awesome software, without rolling your own sync.

Specifically, Electric is a read-path sync engine for Postgres. It syncs data out of Postgres into ... anything you like. The core sync protocol is based on a low-level [HTTP API](https://electric-sql.com/docs/api/http). This integrates with CDNs for highly-scalable data delivery.

Partial replication is managed using [Shapes](https://electric-sql.com/docs/guides/shapes). Sync can be consumed directly or via [client libraries](https://electric-sql.com/docs/api/clients/typescript) and [framework integrations](https://electric-sql.com/docs/api/integrations/react).

## Getting Started

See the [Quickstart guide](https://electric-sql.com/docs/quickstart) to get up and running. In short, you need to:

1. have a Postgres database with logical replication enabled; and then to
2. run Electric in front of it, connected via `DATABASE_URL`

For example, using [Docker Compose](https://docs.docker.com/compose/) from the root of this repo:

```sh
docker compose -f .support/docker-compose.yml up
```

You can then use the [HTTP API](https://electric-sql.com/docs/api/http) to sync data from your Postgres. For example, to start syncing the whole `foo` table:

```sh
curl -i 'http://localhost:3000/v1/shape?table=foo&offset=-1'
```

Or use one of the clients or integrations, such as the [`useShape`](https://electric-sql.com/docs/api/integrations/react) React hook:

```jsx
import { useShape } from '@electric-sql/react'

function Component() {
  const { data } = useShape({
    url: `http://localhost:3000/v1/shape`,
    params: {
      table: `foo`,
      where: `title LIKE 'foo%'`,
    },
  })

  return JSON.stringify(data)
}
```

Again, see the [Quickstart](https://electric-sql.com/docs/quickstart) and the [Docs](https://electric-sql.com) for more details.

## HTTP API Docs

The HTTP API is defined in an [OpenAPI spec](https://swagger.io/specification/) in [website/electric-api.yaml](./website/electric-api.yaml).

## Phoenix LiveDashboard

Electric includes an optional [Phoenix LiveDashboard](https://github.com/phoenixframework/phoenix_live_dashboard) for real-time monitoring of the running system (VM metrics, process info, ETS tables, etc.).

To enable it, set the `ELECTRIC_LIVE_DASHBOARD_PORT` environment variable:

```sh
ELECTRIC_LIVE_DASHBOARD_PORT=4000
```

The dashboard will be available at `http://localhost:4000` (or whichever port you choose). When the variable is not set, the dashboard is not started.

> **WARNING: The LiveDashboard endpoint is completely unauthenticated.** Anyone with network access to the port can view internal system state. In production, you **must** restrict access to this port using firewall rules, network policies, or similar controls. Do not expose it to the public internet.

## Developing Electric

We use [asdf](https://asdf-vm.com/) to install Elixir, Erlang, and Node.js. Versions are defined in [.tool-versions](.tool-versions).

### Mac setup

```sh
brew install asdf
asdf plugin add nodejs
asdf plugin add pnpm
asdf plugin add elixir
asdf plugin add erlang
asdf install
```

You'll probably need to fiddle with your bash/zsh/etc rc file to load the right tool into your environment.

### Running Tests

Electric has comprehensive test suites for both Elixir and TypeScript components.

#### Prerequisites

Install dependencies (if not already done):

```sh
asdf install
pnpm install
```

Then start the test Postgres database:

```sh
cd packages/sync-service
mix start_dev
```

This starts a Docker Compose setup with Postgres configured for logical replication on port 54321.

To stop the database:

```sh
mix stop_dev
```

#### Elixir Tests

**Sync Service:**

```sh
cd packages/sync-service
mix test
```

For coverage reports:

```sh
mix coveralls.html
```

**Elixir Client:**

```sh
cd packages/elixir-client
mix test
```

#### TypeScript Tests

TypeScript tests require both the database and a running sync service.

In a separate terminal, start the sync service:

```sh
cd packages/sync-service
iex -S mix
```

Then run the tests:

**Individual Package:**

```sh
cd packages/typescript-client  # or any other TS package
pnpm test
```

**All TypeScript Packages:**

From the root directory:

```sh
pnpm -r test
```

For coverage:

```sh
pnpm coverage
```

## Contributing

See the:

- [Guide to Contributing](https://github.com/electric-sql/electric/blob/main/CONTRIBUTING.md)
- [Contributor License Agreement](https://github.com/electric-sql/electric/blob/main/CLA.md)
- [Community Guidelines](https://github.com/electric-sql/electric/blob/main/CODE_OF_CONDUCT.md)

## Support

We have an [open community Discord](https://discord.electric-sql.com). Come and say hello and let us know if you have any questions or need any help getting things running.

It's also super helpful if you leave the project a star here at the [top of the page☝️](#start-of-content)
