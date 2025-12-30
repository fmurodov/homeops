# Troubleshooting Guide

Common issues and solutions for the homeops Kubernetes cluster.

## Table of Contents

- [Listing All Resources in a Namespace](#listing-all-resources-in-a-namespace)
- [Namespace Stuck in Terminating State](#namespace-stuck-in-terminating-state)

## Listing All Resources in a Namespace

### Problem

You need to find all resources in a namespace to debug deployment issues, check what's actually deployed, or verify cleanup.

### Solution

List all resources in a specific namespace:

```bash
kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get --show-kind --ignore-not-found -n <namespace> 2>&1
```

**Example:**
```bash
kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get --show-kind --ignore-not-found -n home-assistant 2>&1
```

**What this does:**
1. Gets all API resources that support the `list` verb and are namespaced
2. For each resource type, queries the specified namespace
3. Shows all resources with their kind (e.g., `deployment.apps/name`)
4. Ignores resource types that don't exist in the namespace

**Use cases:**
- Debugging why an application isn't deploying (checking for missing Deployments, StatefulSets, etc.)
- Verifying Flux/Helm has actually created resources
- Finding orphaned resources in a namespace
- Comprehensive namespace audit

## Namespace Stuck in Terminating State

### Problem

A namespace gets stuck in `Terminating` state and won't delete, usually due to finalizers that can't complete.

### Solution

Force remove finalizers from all namespaces stuck in terminating state:

```bash
kubectl get ns --field-selector status.phase=Terminating -o json | \
  jq -r '.items[].metadata.name' | \
  xargs -I {} sh -c 'kubectl get ns {} -o json | jq ".spec.finalizers = []" | kubectl replace --raw /api/v1/namespaces/{}/finalize -f -'
```

**What this does:**
1. Finds all namespaces in `Terminating` state
2. For each namespace, removes all finalizers
3. Finalizes the namespace deletion via the Kubernetes API

**Warning:** This bypasses normal cleanup procedures. Use only when necessary and ensure you understand the implications for your resources.

### Alternative: Remove Finalizers from Specific Namespace

If you want to target a specific namespace:

```bash
NAMESPACE="your-namespace-name"
kubectl get ns $NAMESPACE -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw /api/v1/namespaces/$NAMESPACE/finalize -f -
```
