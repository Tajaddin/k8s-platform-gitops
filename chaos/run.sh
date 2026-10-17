#!/usr/bin/env bash
# Chaos test with a probe: an uncached BM25 search every 0.5 s through the ingress while (1) all search API pods are
# deleted and (2) the agent node is cordoned and drained. Writes chaos/results/<timestamp>.json with the
# failure windows measured by the probe, which docs/POSTMORTEM.md is written from. The drain is followed by
# an uncordon window, because a pod pinned to the node by local storage only returns then.
#   chaos/run.sh                 # both experiments
#   chaos/run.sh pods|node       # one of them
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="${BASE:-https://localhost:8443}"   # TLS from the platform CA; -k because that CA is local
HOST="${HOST:-search.localtest.me}"
NS="${NS:-search}"
NODE="${NODE:-k3d-portfolio-agent-0}"
OUT="chaos/results"
mkdir -p "$OUT"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
PROBE_LOG=$(mktemp)

probe() {  # timestamp, status per line; a real uncached search, so a lost OpenSearch counts as an outage too
  while true; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $HOST" "$BASE/api/search?q=wireless%20mouse&ranker=bm25&size=1&no_cache=true" || echo 000)
    echo "$(date +%s.%N) $code" >> "$PROBE_LOG"
    sleep 0.5
  done
}

window() {  # name, start epoch -> prints JSON with the failed window measured since start
  python3 - "$1" "$2" "$PROBE_LOG" <<'EOF'
import sys, json
name, start, log = sys.argv[1], float(sys.argv[2]), sys.argv[3]
rows = [(float(a), b) for a, b in (l.split() for l in open(log) if l.strip()) if float(a) >= start]
fails = [t for t, c in rows if c != "200"]
first_fail = min(fails) if fails else None
last_fail = max(fails) if fails else None
after = [t for t, c in rows if c == "200" and last_fail and t > last_fail]
recovered = min(after) if after else None
print(json.dumps({
    "experiment": name,
    "probes": len(rows),
    "failed_probes": len(fails),
    "first_failure_s_after_action": round(first_fail - start, 2) if first_fail else None,
    "recovery_s_after_action": round(recovered - start, 2) if recovered else (0.0 if not fails else None),
    "outage_s": round(recovered - first_fail, 2) if (fails and recovered) else (0.0 if not fails else None),
}))
EOF
}

probe & PROBE_PID=$!
trap 'kill $PROBE_PID 2>/dev/null || true' EXIT
sleep 10
RESULTS=()

if [ "${1:-both}" != "node" ]; then
  echo "== experiment 1: delete every search API pod"
  START=$(date +%s.%N)
  kubectl -n "$NS" delete pod -l app.kubernetes.io/name=search-api --wait=false
  sleep 90
  RESULTS+=("$(window delete-all-api-pods "$START")")
  echo "${RESULTS[-1]}"
fi

if [ "${1:-both}" != "pods" ]; then
  echo "== experiment 2: cordon and drain $NODE"
  START=$(date +%s.%N)
  kubectl cordon "$NODE"
  kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --grace-period=20 --timeout=180s || true
  sleep 120
  RESULTS+=("$(window cordon-and-drain-node "$START")")
  echo "${RESULTS[-1]}"
  # a pod pinned to the drained node by local storage can only come back once the node is schedulable again
  echo "== experiment 2b: uncordon $NODE"
  START=$(date +%s.%N)
  kubectl uncordon "$NODE"
  sleep 90
  RESULTS+=("$(window uncordon-node "$START")")
  echo "${RESULTS[-1]}"
fi

kill $PROBE_PID 2>/dev/null || true
python3 - "$OUT/$STAMP.json" "${RESULTS[@]}" <<'EOF'
import sys, json
path, *results = sys.argv[1:]
json.dump({"results": [json.loads(r) for r in results]}, open(path, "w"), indent=2)
print("wrote", path)
EOF
