# Deploying

## Local (k3d)

`make bootstrap` does everything: a k3d cluster with one server and one agent (Traefik disabled, ports
8180/8443 mapped, the P8 data directories mounted), the three local images imported, a git daemon in
Docker serving this repository, Argo CD from its Helm chart, and the root Application. Argo CD then
installs the platform in sync waves and the two workloads; the first full sync pulls about 3 GB of
upstream images and takes 10 to 15 minutes on a laptop.

`make push` after a commit pushes `main` to the local daemon; Argo CD picks it up within a minute. The
Argo CD UI is a port-forward (`make argocd-ui`); Grafana is `https://grafana.localtest.me:8443`.

Resource footprint: about 6 GB of memory for the platform plus the workloads (OpenSearch 1.5 GB, the search
API 1 GB per replica, Prometheus 0.5 GB). Stop the Compose stacks of the other projects first: on Docker
Desktop the WSL VM has half the host's RAM (15.5 GB on a 32 GB machine), and this cluster next to the
search project's own Compose stack and a GPU training container OOM-killed the Docker engine once during
development. `k3d cluster stop portfolio` while another stack is under test, `k3d cluster start portfolio`
after; Argo CD resumes where it was.

## Oracle Cloud always-free VM (k3s)

1. The same OCI API key setup as P8 (`docs/DEPLOY.md` there). `cp infra/terraform/terraform.tfvars.example
   infra/terraform/terraform.tfvars`, fill in tenancy, user, fingerprint, key path, compartment, your SSH
   public key and your address as `admin_cidr`.
2. The cloud overlay (`envs/oci`) pulls the service images from GHCR: push the P6 and P8 images there first
   (`make deploy` in P8 does; for P6 build and push `ghcr.io/<you>/demand-forecast-pricing/api`). Set the
   hosts in `envs/oci/values/*.yaml` to DNS names that point at the VM, and the Let's Encrypt e-mail in
   `platform-extras.yaml`. Commit and push this repository to GitHub, because Argo CD on the VM follows it.
3. `terraform -chdir=infra/terraform apply`. cloud-init installs k3s without Traefik, Helm, Argo CD and the
   root Application for `envs/oci`; `/var/log/platform-bootstrap.log` on the VM shows progress.
4. Copy the P8 prepared data to the VM (`rsync -az data/prepared/ ubuntu@<ip>:/mnt/hss-prepared/`), then
   seal the two secrets against the new cluster: fetch the kubeconfig (`terraform output kubeconfig_hint`),
   install `kubeseal`, and run `scripts/seal.sh oci search search-api-secrets HSS_ADMIN_KEY=<value>` and
   `scripts/seal.sh oci forecast forecast-api-secrets DFP_API_KEYS=<keys>`; commit the files under
   `envs/oci/secrets` and reference them from the charts' extra manifests (or apply them once by hand).
   Back up the controller's sealing key (`kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`).
5. Point DNS at the VM; cert-manager issues the certificates; open the hosts.
6. `terraform destroy` removes the VM and the network.

The A1 shape is popular; if the region reports no capacity, try another availability domain or region.

## What is not automated

- Pushing images to GHCR for P6 (P8's deploy script does its own).
- Chart version bumps inside the Application manifests.
- A CI job that applies Terraform: it needs the OCI key as a GitHub secret.
