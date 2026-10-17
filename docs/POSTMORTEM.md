# Postmortem: two induced failures on the local platform, 2026-10-17

Written from `chaos/results/20261017T205222Z.json` (the probe's numbers) and the cluster's events. The
probe was an uncached BM25 search every 0.5 s through the TLS ingress (`chaos/run.sh`), so it fails when
the search API, the ingress or OpenSearch is unavailable; a failed probe waits up to 5 s, which is why
the probe count is lower in the windows with many failures. The cluster: k3d with one server and one
agent node, two search API replicas (Argo Rollout, PDB `minAvailable: 1`), OpenSearch as a one-replica
StatefulSet on a `local-path` volume, Redis, the forecast API and MLflow, Argo CD and the monitoring
stack. Nothing was warmed or prepared for the experiments beyond waiting for the HPA to return to its
baseline of two replicas after the load test.

## Experiment 1: delete every search API pod at once

| | |
|---|---|
| action | `kubectl delete pod -l app.kubernetes.io/name=search-api` (both replicas) |
| first failed probe | 0.9 s after the action |
| last failed probe | 23 s later |
| outage | **23.1 s** (26 failed probes of 126 in the 90 s window) |
| recovered | 24.0 s after the action |

**What happened.** Both pods were terminated at once. A PodDisruptionBudget does not apply here: it
protects against *evictions* (drains, the descheduler), not against a direct delete, so `minAvailable: 1`
did nothing. The Rollout's ReplicaSet created two new pods immediately; each one loads two
sentence-transformer models from the models volume and warms the index, then waits for its readiness
probe, which has `initialDelaySeconds: 20`. The first replica reported ready about 23 s after the delete,
and the ingress sent traffic to it on the next endpoint update.

**Why 23 s and not 5.** The time is dominated by the readiness delay and the model load, in that order.
The containers were running within 2 s (the image is on the node); the application was listening within
about 8 s; the kubelet did not ask it until second 20.

**Actions.**
- Replace the fixed `initialDelaySeconds: 20` on readiness with a `startupProbe` that polls `/health`
  every 2 s from the start, so a pod that is ready at 8 s is used at 8 s. Expected outage for the same
  experiment: about 10 s.
- A direct delete of all replicas is a human or automation mistake, not an infrastructure event; the
  guard against it is RBAC on `delete pods` in production namespaces plus the Rollout's own restart
  (`spec.restartAt`), which rolls pods one at a time. Both are noted in `docs/DEPLOY.md`.

## Experiment 2: cordon and drain the agent node

| | |
|---|---|
| action | `kubectl drain k3d-portfolio-agent-0 --ignore-daemonsets --delete-emptydir-data --force` |
| first failed probe | 6.3 s after the action |
| recovered | **not within the 120 s window** (61 failed probes of 62) |

**What happened.** The drain evicted 19 pods from the agent: one of the two search API replicas (the
PDB kept the other one, and it was already on the server node), one forecast API replica, MLflow,
Loki, Argo CD's controller, repo-server and redis, cert-manager's webhook and cainjector, the
prometheus-adapter, metrics-server, CoreDNS, kube-state-metrics, and **`opensearch-0`**. Every stateless
pod was rescheduled on the server node within seconds. OpenSearch was not: its PersistentVolume is a
`local-path` volume, which carries a node affinity to the agent, so the replacement pod stayed `Pending`
with "volume node affinity conflict" for as long as the node was cordoned. The search API stayed up
(one replica, then two), but every search needs OpenSearch, so the probe failed from 6 s in until the
end of the window. The ingress, the UI and the forecast API were fine throughout; the forecast API's
MLflow dependency is only needed at start-up and on reload, so losing MLflow (also pinned) did not take
it down.

**The 6 s.** The drain evicted the agent's search API pod first; for about 6 s the remaining replica
served searches from a still-running OpenSearch. The failures start when `opensearch-0` is evicted.

## Experiment 2b: uncordon the node

| | |
|---|---|
| action | `kubectl uncordon k3d-portfolio-agent-0` |
| first failed probe | 0.6 s after the action (the probe was already failing) |
| recovered | **27.4 s** after the action |
| outage from uncordon to recovery | 26.8 s (38 failed probes of 131 in the 90 s window) |

**What happened.** The scheduler placed `opensearch-0` back on the agent as soon as it was schedulable;
the JVM started, recovered the shard from disk and answered searches 27 s later. The time is OpenSearch
start-up, not Kubernetes.

**Actions.**
- The real finding: a one-replica OpenSearch on node-local storage is a single point of failure that a
  drain exposes in full. The honest options, in order of cost: (1) accept it on the one-VM cloud
  environment, where there is no second node to drain to anyway, and document it, which is what this
  repository does; (2) network-attached storage (a block volume on the cloud VM, Longhorn or a CSI driver
  on k3s) so the pod can follow the data; (3) a three-node OpenSearch with one replica shard per index,
  which doubles memory. The README's Limitations section says which one is in force.
- Forecast is in better shape only because its dependency is start-up-only. A liveness probe that
  checked MLflow would have made it worse; it checks `/metrics`, which is the right call.
- The drain also removed CoreDNS and the Argo CD controller from the agent. Both came back on the server
  node in seconds, but on a two-node cluster a `topologySpreadConstraint` or a second replica for CoreDNS
  is cheap insurance. Argo CD being briefly absent does not affect running workloads.

## What the numbers mean for the design

- Stateless replicas on a Rollout recover from the worst case (all pods gone) in the time it takes one
  pod to become ready; shortening that is a probe change, not an architecture change.
- Every stateful singleton on local storage turns a node operation into a user-visible outage for as
  long as the node is out, plus its own start-up time. The probe measured this honestly because it is a
  real search, not a health endpoint that returns 200 while the index is unreachable.
- The PDB did exactly what it promises during the drain (one API replica stayed) and nothing during the
  delete, which is why both experiments are kept.

## Timeline (local time, 2026-10-17)

| time | event |
|---|---|
| 16:52:22 | HPA back at 2 replicas after the load test; probe started |
| 16:52:32 | experiment 1: both search API pods deleted |
| 16:52:33 | first failed probe |
| 16:52:56 | first successful probe; both replacements ready shortly after |
| 16:54:02 | experiment 2: agent node cordoned and drained (19 evictions) |
| 16:54:08 | first failed probe (`opensearch-0` evicted) |
| 16:56:02 | window closed without recovery; `opensearch-0` Pending on volume node affinity |
| 16:56:03 | experiment 2b: node uncordoned |
| 16:56:30 | first successful probe; OpenSearch back on the agent |
| 16:57:33 | probe stopped; cluster fully healthy |
