# Conftest policies applied to every rendered manifest in CI: the guard rails a platform team asks for.
package main

import rego.v1

is_workload(kind) if kind in {"Deployment", "StatefulSet", "Rollout", "Job"}

containers(obj) := obj.spec.template.spec.containers if is_workload(obj.kind)

deny contains msg if {
	some c in containers(input)
	not c.resources.requests
	msg := sprintf("%s/%s container %s has no resource requests", [input.kind, input.metadata.name, c.name])
}

deny contains msg if {
	some c in containers(input)
	not c.resources.limits.memory
	msg := sprintf("%s/%s container %s has no memory limit", [input.kind, input.metadata.name, c.name])
}

# A tag that moves (latest, or none at all) changes what runs without a change in git, so Argo CD never syncs
# and a canary never runs. A version tag or a digest pins the image.
floating(image) if endswith(image, ":latest")

floating(image) if {
	not contains(image, "@")
	path := split(image, "/")
	not contains(path[count(path) - 1], ":")
}

deny contains msg if {
	some c in containers(input)
	floating(c.image)
	msg := sprintf("%s/%s container %s uses :latest or no tag; pin a version or a digest", [input.kind, input.metadata.name, c.name])
}

deny contains msg if {
	input.kind in {"Deployment", "Rollout"}
	input.metadata.labels["app.kubernetes.io/name"] in {"search-api", "forecast-api"}
	not input.spec.template.spec.securityContext.runAsNonRoot
	msg := sprintf("%s/%s must run as non-root", [input.kind, input.metadata.name])
}

deny contains msg if {
	some v in input.spec.template.spec.volumes
	is_workload(input.kind)
	v.hostPath
	msg := sprintf("%s/%s mounts hostPath volume %s; pre-provision it as a PersistentVolume", [input.kind, input.metadata.name, v.name])
}

deny contains msg if {
	input.kind == "Ingress"
	not input.spec.ingressClassName
	msg := sprintf("Ingress/%s has no ingressClassName", [input.metadata.name])
}

deny contains msg if {
	input.kind == "Service"
	input.spec.type == "NodePort"
	msg := sprintf("Service/%s is a NodePort; use the ingress", [input.metadata.name])
}
