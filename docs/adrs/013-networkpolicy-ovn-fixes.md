# ADR-013: NetworkPolicy Fixes for OVN-Kubernetes

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

During Sprint 1 execution, we discovered that the original NetworkPolicy for `agent-sandboxes` blocked legitimate traffic in three ways:

1. **DNS resolution failed**: Two compounding issues. First, OpenShift CoreDNS pods listen on port **5353** (the `dns-default` Service remaps 53→5353). OVN-Kubernetes evaluates NetworkPolicy port matching **post-DNAT**, so the port at the pod level is 5353, not 53. A policy allowing only port 53 silently drops DNS queries. Second, the CoreDNS ClusterIP (`172.30.0.10`) falls within the `172.16.0.0/12` range excluded by the external egress rule, but this is moot since `namespaceSelector: {}` matches the actual pod, not the ClusterIP.

2. **Build pods blocked**: OpenShift build pods (`oc start-build`) need to pull base images from external registries, connect to the K8s API server (`172.30.0.1:443`), and push to the internal image registry (`image-registry.openshift-image-registry.svc:5000`). The agent egress policy blocked all of these because they use private IP ranges.

3. **Agent pods couldn't reach vLLM**: Although the egress rule allowed port 8080 to the `inference` namespace, DNS resolution failed first, preventing the agent from resolving `qwen25-14b.inference.svc.cluster.local`.

## Decision

Split the `agent-sandboxes` egress into two policies:

1. **Agent pods** (`openshift.io/build.name` does NOT exist): Restricted egress with an additional rule allowing traffic to the Kubernetes Service CIDR (`172.30.0.0/16`) for DNS and API server access.

2. **Build pods** (`openshift.io/build.name` exists): Unrestricted egress — they're short-lived and need broad access to pull images and push to registries.

## Key Changes

```yaml
# DNS: add port 5353 (CoreDNS actual port in OpenShift, post-DNAT)
- to:
    - namespaceSelector: {}
  ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
    - port: 5353
      protocol: UDP
    - port: 5353
      protocol: TCP
```

```yaml
# Build pods: separate policy with unrestricted egress
spec:
  podSelector:
    matchExpressions:
      - key: openshift.io/build.name
        operator: Exists
  egress:
    - {}
```

## Consequences

- Agent pods can now resolve DNS and reach vLLM via service names
- Build pods are not restricted by the agent egress policy
- The temporary `allow-claude-egress-temp` and `allow-builds-egress` policies created ad-hoc during Sprint 1 are replaced by the permanent policies in `network-policies.yaml`
- The Service CIDR `172.30.0.0/16` is specific to this cluster — production clusters may use a different CIDR
