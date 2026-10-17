# 0001. k3s everywhere: k3d on the laptop, k3s on a free VM, no managed cluster

Date: 2026-10-17

## Context

The brief asks for Kubernetes with Terraform, GitOps and monitoring at a cost near zero, and allows AKS
free tier, k3s on one VM, or EKS with approval. The platform must also be demonstrable end to end on the
laptop, because the numbers in the README (autoscaling reaction, recovery after failures) have to be
reproduced by a committed script.

## Decision

- **Locally: k3d** (k3s in Docker) with one server and one agent, Traefik disabled so ingress-nginx is the
  same in both environments, and the host directories with the search catalog and model cache mounted.
  Everything in the repository applies to it unchanged.
- **In the cloud: k3s on an Oracle Cloud always-free ARM VM** created by Terraform and bootstrapped by
  cloud-init, which installs k3s without Traefik, Helm, Argo CD and the root application. One node is
  enough for the two services and keeps the bill at zero; a second always-free instance can join later.
- **Not a managed control plane.** AKS free tier and EKS add a credential, a billing surface and a provider
  module for the same manifests; the GitOps layer is where the platform work is, and it is identical on k3s.

## Consequences

- One node means node-level failure is a drain, not a loss; the chaos test says so.
- Two agents locally would make the drain experiment more realistic; the laptop has one, which also keeps
  the resource footprint small enough to run next to the other projects.
- Moving to a managed cluster later is a new Terraform module and an `envs/<cloud>` overlay; charts and
  applications stay.
