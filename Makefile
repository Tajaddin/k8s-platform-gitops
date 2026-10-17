.PHONY: bootstrap push status lint render validate policy tf-validate load chaos report argocd-ui grafana-ui canary-good canary-bad clean

bootstrap:      ## k3d cluster, local git daemon, Argo CD, root app (10 to 15 minutes the first time)
	bash scripts/bootstrap-local.sh

push:           ## commit first; then push main to the local git daemon so Argo CD syncs it
	bash scripts/bootstrap-local.sh push

status:
	kubectl get applications -n argocd
	kubectl get pods -A | grep -vE "Running|Completed" || true

lint:
	for c in charts/*; do helm lint $$c -f envs/local/values/$$(basename $$c).yaml; done

render:         ## rendered manifests for both envs under out/
	mkdir -p out
	for env in local oci; do for c in charts/*; do n=$$(basename $$c); helm template $$n $$c -n $$n -f envs/$$env/values/$$n.yaml > out/$$env-$$n.yaml; done; kubectl kustomize envs/$$env/apps > out/$$env-apps.yaml; done

validate: render
	kubeconform -strict -ignore-missing-schemas -summary out/*.yaml

policy: render
	conftest test out/*.yaml -p platform/policies

tf-validate:
	docker run --rm -v "$(CURDIR):/w" -w /w/infra/terraform hashicorp/terraform:1.9 fmt -check
	docker run --rm -v "$(CURDIR):/w" -w /w/infra/terraform hashicorp/terraform:1.9 init -backend=false -input=false >/dev/null && docker run --rm -v "$(CURDIR):/w" -w /w/infra/terraform hashicorp/terraform:1.9 validate

load:           ## k6 ramp through the ingress while the HPA is sampled -> load/results/hpa-<stamp>.json
	bash scripts/measure-hpa.sh

chaos:          ## delete the API pods, then drain the agent node, with a probe measuring the outage
	bash chaos/run.sh

canary-bad:     ## roll out an image that fails health checks and watch the analysis abort it
	kubectl -n search argo rollouts set image search-api api=hss/api:broken || kubectl argo rollouts -n search set image search-api api=hss/api:broken

report:         ## render load/results and chaos/results into README.md
	python scripts/render_results.py --write

argocd-ui:
	@echo "admin / $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	kubectl -n argocd port-forward svc/argocd-server 8081:80

grafana-ui:
	@echo "admin / change-me-local-only at https://grafana.localtest.me:8443"

clean:
	k3d cluster delete portfolio
	docker rm -f gitops-daemon || true
