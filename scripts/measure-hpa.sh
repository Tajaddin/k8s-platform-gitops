#!/usr/bin/env bash
# Autoscaling reaction time: runs the k6 ramp and, in parallel, samples the HPA and the API pods every 5 s.
# Writes load/results/hpa-<timestamp>.json with the time from the load step to the first new replica ready
# and the replica counts over time. Reads: kubectl, docker (for k6).
set -euo pipefail
cd "$(dirname "$0")/.."
NS="${NS:-search}"
BASE="${BASE:-https://host.docker.internal:8443}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="load/results"
mkdir -p "$OUT"
SAMPLES="$OUT/hpa-samples-$STAMP.log"

sample() {
  while true; do
    now=$(date +%s)
    hpa=$(kubectl -n "$NS" get hpa search-api -o jsonpath='{.status.currentReplicas} {.status.desiredReplicas} {.status.currentMetrics[*].pods.current.averageValue}{.status.currentMetrics[*].resource.current.averageUtilization}' 2>/dev/null || echo "? ? ?")
    ready=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=search-api -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -c True || true)
    echo "$now $hpa ready=$ready" >> "$SAMPLES"
    sleep 5
  done
}

sample & SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT
START=$(date +%s)
echo "== load from $(date -u +%H:%M:%S) (the step to 60 rps happens at +60 s)"
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD/load:/scripts:ro" -v "$PWD/$OUT:/out" grafana/k6:0.57.0 run -e BASE="$BASE" /scripts/hpa-load.js | tail -20
kill $SAMPLER 2>/dev/null || true

python3 - "$SAMPLES" "$START" "$OUT/hpa-$STAMP.json" <<'EOF'
import sys, json
samples, start, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rows = []
for line in open(samples):
    parts = line.split()
    if len(parts) < 4:
        continue
    t = int(parts[0]); cur = parts[1]; desired = parts[2]; ready = int(parts[-1].split("=")[1])
    rows.append({"t": t - start, "current": cur, "desired": desired, "ready": ready})
base_ready = rows[0]["ready"] if rows else None
step_at = 60  # the ramp to 60 rps starts 60 s in
first_desired_up = next((r["t"] for r in rows if r["t"] >= step_at and r["desired"].isdigit() and int(r["desired"]) > int(rows[0]["desired"] if rows[0]["desired"].isdigit() else 0)), None)
first_ready_up = next((r["t"] for r in rows if r["t"] >= step_at and base_ready is not None and r["ready"] > base_ready), None)
peak = max((r["ready"] for r in rows), default=None)
result = {
    "baseline_ready_replicas": base_ready,
    "load_step_at_s": step_at,
    "hpa_desired_increase_at_s": first_desired_up,
    "first_new_replica_ready_at_s": first_ready_up,
    "reaction_s_from_load_step_to_new_replica_ready": (first_ready_up - step_at) if first_ready_up else None,
    "peak_ready_replicas": peak,
    "samples": rows,
}
json.dump(result, open(out, "w"), indent=2)
print(json.dumps({k: v for k, v in result.items() if k != "samples"}, indent=2))
print("wrote", out)
EOF
