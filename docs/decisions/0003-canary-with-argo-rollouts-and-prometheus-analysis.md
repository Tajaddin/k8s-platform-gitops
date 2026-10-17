# 0003. Canary rollouts with Argo Rollouts gated by Prometheus analysis, HPA on CPU and traffic

Date: 2026-10-17

## Context

The brief asks for a canary or blue-green rollout and for horizontal autoscaling demonstrated under load.
The search API is the stateful-dependency-free, latency-sensitive service that benefits from both.

## Decision

- The search API is an **Argo Rollout** with a canary strategy through the ingress-nginx traffic router:
  10% of traffic to the new ReplicaSet, a pause, an analysis run, 50%, a pause, an analysis run, then
  full promotion. The **AnalysisTemplate** queries Prometheus for the 5xx share and the p99 of `/search`
  over the last two minutes; one failed measurement aborts the rollout and the stable ReplicaSet keeps
  serving. A deliberately broken image is the test case.
- **HPA** targets the Rollout with two metrics: CPU utilisation and `http_requests_per_second` per pod,
  served by prometheus-adapter from the API's own request histogram. Scale-up has no stabilisation
  window and adds two pods per 30 seconds; scale-down waits two minutes.
- The forecast API uses a plain Deployment with a rolling update (one surge, zero unavailable) and a
  CPU HPA: it is a lower-traffic service and one canary demonstration is enough.
- PodDisruptionBudgets with one pod always available, so the chaos drain and the rollout cannot take the
  last pod.

## Consequences

- The canary needs the metrics pipeline to be healthy; an outage of Prometheus pauses rollouts, which is
  the conservative failure mode.
- The traffic metric lags by the scrape and adapter interval (about 30 to 45 seconds); the README reports
  the measured reaction time rather than a nominal one.
