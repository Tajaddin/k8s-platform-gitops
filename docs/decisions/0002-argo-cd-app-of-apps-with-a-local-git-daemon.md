# 0002. Argo CD app-of-apps, fed by a local git daemon on the laptop and GitHub in the cloud

Date: 2026-10-17

## Context

GitOps means the cluster follows a git repository; nothing is applied by hand after the bootstrap. The
owner's rule is that nothing is pushed to GitHub without their say, so the local demonstration cannot
depend on the GitHub repository existing or being current.

## Decision

- **Argo CD** installed by the bootstrap (Helm, pinned chart version) with one hand-applied root
  Application that points at `envs/<env>/apps`. Every other Application lives there, with sync waves:
  controllers and CRDs first (ingress-nginx, cert-manager, Sealed Secrets, Argo Rollouts), then
  monitoring (kube-prometheus-stack, Loki, Promtail), then the platform extras that need those CRDs
  (issuer, baseline network policies), then the workloads. Automated sync with prune and self-heal.
- **Locally the repository is served to the cluster by a git daemon** running in Docker next to the
  cluster; `make push` pushes the current commit to it and Argo CD syncs within a minute. The cloud
  environment's applications point at the GitHub repository. The two environments differ only in
  `envs/<env>`: repository URL, image references, hosts, storage class, issuer and whether secrets are
  sealed.
- Upstream charts are referenced by chart repository and version with our values files from this
  repository (multi-source Applications); our own charts live under `charts/`.

## Consequences

- The local loop is commit, push to the daemon, watch Argo CD; no GitHub round trip and no credentials.
- Argo CD's own install is the one thing not managed by Argo CD; upgrading it is a bootstrap re-run.
- Renovate or Dependabot cannot bump chart versions inside Application manifests out of the box; a
  small workflow or manual bumps are needed, and that is noted in the README.
