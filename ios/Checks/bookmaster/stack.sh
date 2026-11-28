#!/bin/sh
# stack.sh reset | start-bm | start-pt | stop-bm-only | stop
#   BookMaster on :8788 (fresh local D1), the Pageturner bridge on :8789 pointing at it,
#   two accounts (pengu, kristenkrae) and a one-time link code in .work/code.
# Needs BOOKMASTER_REPO — a BookMaster checkout with `npm ci` done.
HERE=$(cd "$(dirname "$0")" && pwd)
PT_ROOT=$(cd "$HERE/../.." && pwd)/..
WORK="$HERE/.work"; mkdir -p "$WORK"
: "${BOOKMASTER_REPO:?set BOOKMASTER_REPO to a BookMaster checkout}"
WRANGLER="$BOOKMASTER_REPO/node_modules/.bin/wrangler"
SECRET=bridge-test-secret

pids() { ps -eo pid,args | awk -v pat="$1" '$0 ~ pat && $0 !~ /awk/ {print $1}'; }
# the servers' own executables, not the bare word "wrangler" (any shell whose command mentions it would match)
SERVERS='node_modules/[.]bin/wrangler|wrangler-dist/cli[.]js|workerd-linux-64/bin/workerd|@esbuild/linux-x64/bin/esbuild'

case "$1" in
start-bm)
  # a throwaway signing key and the bridge secret; removed again by `stop`
  printf 'JWT_SECRET=local-check-secret-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nAPP_URL=http://localhost:8788\nPAGETURNER_SECRET=%s\n' "$SECRET" > "$BOOKMASTER_REPO/.dev.vars"
  cd "$BOOKMASTER_REPO" && setsid nohup "$WRANGLER" pages dev --port 8788 --ip 127.0.0.1 </dev/null >"$WORK/bm.log" 2>&1 &
  ;;
start-pt)
  cd "$PT_ROOT" && setsid nohup "$WRANGLER" pages dev docs --port 8789 --ip 127.0.0.1 \
    --binding BOOKMASTER_URL=http://127.0.0.1:8788 --binding PAGETURNER_SECRET="$SECRET" </dev/null >"$WORK/pt.log" 2>&1 &
  ;;
stop-bm-only)
  # take BookMaster down mid-run (the outage check); workerd goes too, so the caller restarts the bridge
  for p in $(pids 'wrangler.*8788'); do kill "$p" 2>/dev/null; done
  for p in $(pids 'workerd'); do kill "$p" 2>/dev/null; done
  ;;
stop)
  for p in $(pids "$SERVERS"); do kill "$p" 2>/dev/null; done
  # wait until they are really gone: a workerd still holding its port makes the next start fail with "Address already in
  # use" (and the stack then came up half there, which `reset` used to call ready)
  for i in $(seq 1 20); do [ -z "$(pids "$SERVERS")" ] && break; sleep 0.5; done
  for p in $(pids "$SERVERS"); do kill -9 "$p" 2>/dev/null; done
  rm -f "$BOOKMASTER_REPO/.dev.vars"; rm -rf "$PT_ROOT/.wrangler"
  ;;
reset)
  "$0" stop; sleep 2
  printf 'JWT_SECRET=local-check-secret-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nAPP_URL=http://localhost:8788\nPAGETURNER_SECRET=%s\n' "$SECRET" > "$BOOKMASTER_REPO/.dev.vars"
  (cd "$BOOKMASTER_REPO" && rm -rf .wrangler/state && "$WRANGLER" d1 migrations apply bookmaster-db --local >/dev/null 2>&1)
  "$0" start-bm; "$0" start-pt
  for i in $(seq 1 40); do
    a=$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:8788/api/auth/me)
    b=$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:8789/)
    [ "$a" = 401 ] && [ "$b" = 200 ] && break; sleep 2
  done
  # not up is not ready: say so, rather than let the checks fail one by one on a stack that never started
  if ! { [ "$a" = 401 ] && [ "$b" = 200 ]; }; then
    echo "stack did not start (BookMaster answered $a, the bridge $b) — see $WORK/bm.log and $WORK/pt.log" >&2
    exit 1
  fi
  B=http://127.0.0.1:8788
  rm -f "$WORK/cj1" "$WORK/cj2"
  curl -sS -c "$WORK/cj1" -X POST $B/api/auth/register -H 'content-type: application/json' -d '{"username":"pengu","display_name":"Andrew","password":"correct-horse-battery"}' >/dev/null
  curl -sS -c "$WORK/cj2" -X POST $B/api/auth/register -H 'content-type: application/json' -d '{"username":"kristenkrae","display_name":"Kristen","password":"correct-horse-battery"}' >/dev/null
  curl -sS -b "$WORK/cj1" -X POST $B/api/pageturner/link | python3 -c 'import sys,json;print(json.load(sys.stdin)["code"])' > "$WORK/code"
  echo "stack ready"
  ;;
*) echo "usage: $0 reset|start-bm|start-pt|stop"; exit 2 ;;
esac
