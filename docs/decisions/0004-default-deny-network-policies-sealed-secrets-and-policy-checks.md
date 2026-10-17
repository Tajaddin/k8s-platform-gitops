# 0004. Default-deny network policies, Sealed Secrets, and policy checks in CI

Date: 2026-10-17

## Context

The brief asks for network policies and secrets through External Secrets or Sealed Secrets. The
platform also needs guard rails that catch mistakes before a sync, not after.

## Decision

- **Default deny** in every workload namespace (ingress and egress), applied by the platform-extras chart
  together with the namespace itself, plus two baseline allows: DNS to kube-system and scrapes from the
  monitoring namespace. Each workload chart adds its own explicit allows: ingress-nginx to the UI and the
  API, the API to OpenSearch and Redis, the forecast API to MLflow, jobs to what they load. Nothing else
  talks to anything.
- **Sealed Secrets** for environments that live in git: `scripts/seal.sh` encrypts a secret with the
  cluster's controller key and the SealedSecret is committed under `envs/<env>/secrets`. The local
  environment, whose cluster is thrown away and recreated, uses a plain dev-only Secret rendered from
  values with a warning annotation; the chart switch is `secrets.sealed`.
- **Pod security baseline** enforced per namespace by label, non-root containers with dropped
  capabilities, requests and limits everywhere.
- **CI renders every chart for every environment** and runs `kubeconform` (schema) and `conftest` with
  Rego policies: requests and memory limits present, no `:latest` tags outside the monitoring stack and
  our own GHCR images, non-root for the APIs, an ingress class on every Ingress, no NodePort services.

## Consequences

- A new dependency between two pods is a reviewed change to a network policy, which is the point.
- Sealed Secrets tie secrets to one cluster's key; a cluster rebuild means re-sealing, and the key should
  be backed up for a long-lived environment (noted in the deployment guide).
