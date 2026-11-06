# Unit tests for workloads.rego, run in CI with `conftest verify -p platform/policies`. Inputs mirror what
# `helm template` emits: no metadata.namespace on namespaced objects.
package main

import rego.v1

sized := {"requests": {"cpu": "10m"}, "limits": {"memory": "64Mi"}}

app(image, resources) := {"name": "app", "image": image, "resources": resources}

workload(kind, container) := {
	"kind": kind,
	"metadata": {"name": "web"},
	"spec": {"template": {"spec": {
		"securityContext": {"runAsNonRoot": true},
		"containers": [container],
	}}},
}

test_compliant_workloads_pass if {
	every kind in {"Deployment", "StatefulSet", "Rollout", "Job"} {
		count(deny) == 0 with input as workload(kind, app("nginx:1.27", sized))
	}
}

test_container_without_requests_is_denied if {
	"Deployment/web container app has no resource requests" in deny with input as workload(
		"Deployment",
		app("nginx:1.27", {"limits": {"memory": "64Mi"}}),
	)
}

test_container_without_memory_limit_is_denied if {
	"Deployment/web container app has no memory limit" in deny with input as workload(
		"Deployment",
		app("nginx:1.27", {"requests": {"cpu": "10m"}, "limits": {"cpu": "1"}}),
	)
}

test_latest_tag_is_denied_without_a_namespace if {
	"Deployment/web container app uses :latest or no tag; pin a version or a digest" in deny with input as workload(
		"Deployment",
		app("nginx:latest", sized),
	)
}

test_untagged_images_are_denied if {
	every image in {"nginx", "registry.local:5000/team/app"} {
		"Job/web container app uses :latest or no tag; pin a version or a digest" in deny with input as workload(
			"Job",
			app(image, sized),
		)
	}
}

test_own_images_are_not_exempt if {
	"Rollout/web container app uses :latest or no tag; pin a version or a digest" in deny with input as workload(
		"Rollout",
		app("ghcr.io/tajaddin/hybrid-search-service/api:latest", sized),
	)
}

test_versions_and_digests_pass if {
	every image in {
		"registry.local:5000/team/app:1.0",
		"ghcr.io/tajaddin/hybrid-search-service/api:sha-08d4e01",
		"nginx@sha256:0d17b565c37bcbd895e9d92315a05c1c3c9a29f762b011a10c54a66cd53c9b31",
	} {
		count(deny) == 0 with input as workload("Deployment", app(image, sized))
	}
}

test_workload_without_run_as_non_root_is_denied if {
	opensearch := {
		"kind": "StatefulSet",
		"metadata": {"name": "opensearch"},
		"spec": {"template": {"spec": {"securityContext": {"fsGroup": 1000}, "containers": [app("opensearch:2.19.1", sized)]}}},
	}
	"StatefulSet/opensearch must run as non-root, or say why in a platform/runs-as-root annotation" in deny with input as opensearch
}

test_root_workload_with_a_stated_reason_passes if {
	ui := {
		"kind": "Deployment",
		"metadata": {"name": "ui", "annotations": {"platform/runs-as-root": "nginx binds :80 as root"}},
		"spec": {"template": {"spec": {"containers": [app("nginx:1.27", sized)]}}},
	}
	count(deny) == 0 with input as ui
}

test_host_path_volume_is_denied if {
	pod := workload("StatefulSet", app("nginx:1.27", sized))
	with_volume := object.union(pod, {"spec": {"template": {"spec": {"volumes": [{"name": "data", "hostPath": {"path": "/mnt"}}]}}}})
	"StatefulSet/web mounts hostPath volume data; pre-provision it as a PersistentVolume" in deny with input as with_volume
}

test_ingress_needs_a_class if {
	"Ingress/web has no ingressClassName" in deny with input as {"kind": "Ingress", "metadata": {"name": "web"}, "spec": {}}
	count(deny) == 0 with input as {"kind": "Ingress", "metadata": {"name": "web"}, "spec": {"ingressClassName": "nginx"}}
}

test_node_port_service_is_denied if {
	"Service/web is a NodePort; use the ingress" in deny with input as {"kind": "Service", "metadata": {"name": "web"}, "spec": {"type": "NodePort"}}
	count(deny) == 0 with input as {"kind": "Service", "metadata": {"name": "web"}, "spec": {"type": "ClusterIP"}}
}
