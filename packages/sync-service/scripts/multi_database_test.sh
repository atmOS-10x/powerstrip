#!/usr/bin/env bash
# End-to-end check of ELECTRIC_MULTI_DATABASE against a throwaway Postgres, with Docker:
#   scripts/multi_database_test.sh [image]   default image: powerstrip:dev
set -euo pipefail
image=${1:-powerstrip:dev}
id=mdbtest$$
net=$id pg=$id-pg el=$id-el
port=$((40000 + RANDOM % 10000))
fail() { echo "FAIL: $*" >&2; docker logs --tail 40 "$el" >&2 2>&1 || true; exit 1; }
cleanup() { docker rm -f "$el" "$pg" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker network create "$net" >/dev/null
docker run -d --name "$pg" --network "$net" -e POSTGRES_PASSWORD=pw postgres:17-alpine \
  -c wal_level=logical -c max_replication_slots=20 -c max_wal_senders=20 >/dev/null
until docker exec "$pg" pg_isready -U postgres >/dev/null 2>&1; do sleep 0.5; done
sleep 1
psql() { docker exec -i "$pg" psql -v ON_ERROR_STOP=1 -qtA -U postgres "$@"; }
for db in app wt_a wt_b; do
  psql -c "CREATE DATABASE $db"
  psql -d "$db" -c "CREATE TABLE items (id int PRIMARY KEY, label text); INSERT INTO items VALUES (1, 'from $db')"
done

docker run -d --name "$el" --network "$net" -p "127.0.0.1:$port:3000" \
  -e DATABASE_URL="postgresql://postgres:pw@$pg:5432/app?sslmode=disable" \
  -e ELECTRIC_SECRET=s3cret -e ELECTRIC_USAGE_REPORTING=false \
  -e ELECTRIC_MULTI_DATABASE=true -e ELECTRIC_MULTI_DATABASE_PATTERN='app|wt_.*' \
  -e ELECTRIC_MULTI_DATABASE_IDLE_TIMEOUT=10s "$image" >/dev/null
base=http://127.0.0.1:$port
until curl -fsS "$base/v1/health" >/dev/null 2>&1; do sleep 0.5; done

shape() { curl -sS "$base$1/v1/shape?table=items&offset=-1${2-&secret=s3cret}"; }
expect() { case "$2" in *"$3"*) echo "ok   $1" ;; *) fail "$1: got $2" ;; esac; }
reject() { case "$2" in *"$3"*) fail "$1: got $2" ;; *) echo "ok   $1" ;; esac; }

expect "default stack serves DATABASE_URL's database" "$(shape "")" "from app"
expect "/db/wt_a serves wt_a" "$(shape /db/wt_a)" "from wt_a"
reject "/db/wt_a sees nothing of app" "$(shape /db/wt_a)" "from app"
expect "/db/wt_b serves wt_b" "$(shape /db/wt_b)" "from wt_b"

# Each database has its own schema: a migration in one changes nothing in the other.
psql -d wt_b -c "ALTER TABLE items ADD COLUMN priority int DEFAULT 7"
# Electric learns a table's new layout from the next change to it, then has clients refetch.
psql -d wt_b -c "UPDATE items SET label = 'from wt_b' WHERE id = 1"
sleep 2
psql -d wt_b -c "CREATE TABLE notes (id int PRIMARY KEY, body text); INSERT INTO notes VALUES (1, 'only in wt_b')"
expect "a new column shows in its database" "$(shape /db/wt_b)" '"priority":"7"'
reject "and not in another" "$(shape /db/wt_a)" "priority"
expect "a new table syncs in its database" "$(curl -sS "$base/db/wt_b/v1/shape?table=notes&offset=-1&secret=s3cret")" "only in wt_b"
expect "and does not exist in another" "$(curl -sS "$base/db/wt_a/v1/shape?table=notes&offset=-1&secret=s3cret")" "does not exist"
expect "/db/app is the default stack" "$(shape /db/app)" "from app"
expect "the secret guards prefixed paths" "$(curl -sS -o /dev/null -w '%{http_code}' "$base/db/wt_a/v1/shape?table=items&offset=-1")" 401
expect "the pattern limits databases" "$(curl -sS -o /dev/null -w '%{http_code}' "$base/db/postgres/v1/shape?table=items&offset=-1&secret=s3cret")" 404
expect "health per database" "$(curl -sS "$base/db/wt_a/v1/health")" "active"

# Live: a change in wt_a reaches a live request on wt_a.
headers=$(curl -sS -D - -o /dev/null "$base/db/wt_a/v1/shape?table=items&offset=-1&secret=s3cret")
handle=$(sed -n 's/^electric-handle: //Ip' <<<"$headers" | tr -d '\r')
offset=$(sed -n 's/^electric-offset: //Ip' <<<"$headers" | tr -d '\r')
(sleep 1; psql -d wt_a -c "INSERT INTO items VALUES (2, 'live in wt_a')") &
expect "live changes per database" \
  "$(curl -sS "$base/db/wt_a/v1/shape?table=items&handle=$handle&offset=$offset&live=true&secret=s3cret")" "live in wt_a"
wait

slots() { psql -c "SELECT count(*) FROM pg_replication_slots WHERE active"; }
expect "one slot per running database" "$(slots)" 3
mem() { docker stats --no-stream --format '{{.MemUsage}}' "$el" | cut -d/ -f1; }
echo "     memory with 3 databases: $(mem)"
echo "     waiting for the idle timeout"
sleep 25
expect "idle stacks drop their slots" "$(slots)" 1
expect "an idle database starts again" "$(shape /db/wt_b)" "from wt_b"
expect "a shape from before the restart must refetch" \
  "$(curl -sS -o /dev/null -w '%{http_code}' "$base/db/wt_a/v1/shape?table=items&handle=$handle&offset=$offset&secret=s3cret")" 409
expect "DELETE needs the secret" "$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$base/db/wt_b")" 401
expect "DELETE releases a database" "$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$base/db/wt_b?secret=s3cret")" 204
psql -c "DROP DATABASE wt_b WITH (FORCE)"
expect "a released database can be dropped" "$(psql -c "SELECT count(*) FROM pg_database WHERE datname = 'wt_b'")" 0
echo "all checks passed"
