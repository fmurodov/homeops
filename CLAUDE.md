# CLAUDE.md - AI Assistant Guide for HomeOps

This document provides comprehensive guidance for AI assistants (like Claude) working with the HomeOps repository. It explains the codebase structure, development workflows, and key conventions to follow.

## Repository Overview

**HomeOps** is an Infrastructure as Code (IaC) repository for home infrastructure management. It uses:
- **Talos Linux** for Kubernetes cluster nodes (talos1018 - 3-node cluster)
- **Flux CD** for GitOps-based continuous deployment
- **SOPS + age** for secret encryption
- **Renovate** for automated dependency updates

**Repository URL**: https://github.com/fmurodov/homeops
**Main Branch**: master
**Current Cluster**: talos1018 (Kubernetes v1.35.0, Talos v1.12.1)

## Directory Structure

```
homeops/
├── talos/                      # Talos Kubernetes cluster configurations
│   └── talos1018/             # Cluster-specific config (talconfig.yaml)
│       ├── talconfig.yaml     # talhelper config (single source of truth)
│       ├── talsecret.sops.yaml # Encrypted cluster secrets
│       └── clusterconfig/     # Generated configs (DO NOT EDIT)
│
├── kubernetes/                # Flux CD GitOps manifests
│   ├── clusters/             # Flux configurations
│   │   └── talos1018/       # Main cluster Flux config
│   │       ├── flux-system/  # Flux components
│   │       ├── cluster-config.yaml      # Cluster-wide secrets/vars
│   │       ├── infrastructure.yaml      # Infrastructure layer
│   │       └── apps.yaml               # Applications layer
│   │
│   ├── infrastructure/       # Core infrastructure components
│   │   └── talos1018/
│   │       ├── core/        # Cilium, cert-manager, ingress-nginx
│   │       └── storage/     # Longhorn with S3 backups
│   │
│   ├── apps/                # Application deployments (20+ apps)
│   │   └── talos1018/      # Organized by category
│   │
│   ├── components/          # Shared Kustomize components
│   │   └── common/         # cluster-secrets.sops.yaml
│   │
│   └── .sops.yaml          # SOPS encryption rules
│
├── scripts/                 # Automation and validation
│   ├── validate.sh         # Master validation script
│   ├── validate-flux.sh    # Flux manifest validation
│   └── pre-commit          # Git pre-commit hook
│
├── .github/                # CI/CD workflows
│   └── workflows/
│       ├── validate-flux.yaml    # Validates Kubernetes manifests
│       ├── validate-talos.yaml   # Validates Talos configs
│       └── gitleaks.yaml         # Secret scanning
│
├── .renovate/              # Renovate configuration
│   ├── customManagers.json5     # Custom dependency patterns
│   ├── groups.json5             # Grouped updates
│   ├── autoMerge.json5          # Auto-merge rules
│   └── semanticCommits.json5    # Commit message conventions
│
└── docs/                   # Documentation
```

## Key Technologies and Tools

### Required Tools
- `talosctl` - Talos cluster management
- `kubectl` - Kubernetes CLI
- `helm` - Helm package manager
- `flux` - Flux CD CLI
- `sops` - Secret encryption/decryption
- `talhelper` - Talos config generator
- `yq` - YAML processor (for validation)
- `kubeconform` - Kubernetes manifest validator

### Technology Stack
- **OS**: Talos Linux v1.12.1
- **Kubernetes**: v1.35.0
- **CNI**: Cilium v1.18.5 (L2 announcements for LoadBalancer)
- **GitOps**: Flux CD v2
- **Ingress**: ingress-nginx
- **Certificates**: cert-manager with Let's Encrypt (Cloudflare DNS)
- **Storage**: Longhorn v1.10.1 with S3 backups to Cloudflare R2
- **Monitoring**: kube-prometheus-stack v80.12.0

## GitOps Architecture

### Layered Dependency Model

Flux uses a **layered deployment approach** with explicit dependencies:

```
┌─────────────────────┐
│  cluster-config     │  (1) Cluster-wide secrets & variables
└──────────┬──────────┘
           │
      ┌────▼─────────────────────┐
      │    infra-core            │  (2) Core infrastructure
      │  • Cilium (CNI)          │
      │  • cert-manager          │
      │  • ingress-nginx         │
      └────┬─────────────────────┘
           │
      ┌────▼──────────────────────┐
      │    infra-storage          │  (3) Storage layer
      │  • Longhorn               │
      │  • S3 Backups             │
      └────┬──────────────────────┘
           │
      ┌────▼──────────────────────┐
      │    Applications           │  (4) All apps (parallel)
      │  • 20+ applications       │
      │  • Deploy in parallel     │
      └───────────────────────────┘
```

### Component Structure Pattern

Every infrastructure component follows this structure:

```
component-name/
├── app/                     # Helm deployment
│   ├── helmrepository.yaml  # Helm repo source
│   ├── helmrelease.yaml     # Helm chart + values
│   ├── kustomization.yaml   # Resources list
│   └── namespace.yaml       # (optional) Namespace
│
├── config/                  # CRDs and configuration
│   ├── *.yaml              # CRDs, custom resources
│   └── kustomization.yaml
│
└── ks.yaml                 # Flux Kustomization definitions
```

**Example**: `kubernetes/infrastructure/talos1018/core/cilium/`
- `ks.yaml` defines two Kustomizations:
  - `infra-cilium-app` - Deploys HelmRelease
  - `infra-cilium-config` - Applies L2 announcements (depends on app)

### Flux Kustomization Files

Key files that orchestrate deployments:

1. **cluster-config.yaml** (`kubernetes/clusters/talos1018/cluster-config.yaml`)
   - Deploys cluster-wide secrets from `kubernetes/components/common/`
   - Decrypts SOPS secrets using age key
   - Provides variables for other Kustomizations

2. **infrastructure.yaml** (`kubernetes/clusters/talos1018/infrastructure.yaml`)
   - Defines `infra-core` and `infra-storage` Kustomizations
   - Dependencies: infra-storage depends on infra-core

3. **apps.yaml** (`kubernetes/clusters/talos1018/apps.yaml`)
   - Deploys all applications
   - Dependencies: cluster-config and infra-core
   - Apps with PVCs automatically wait for storage via Kubernetes

## Secret Management (SOPS + age)

### Encryption Configuration

**Location**: `kubernetes/.sops.yaml` and `talos/talos1018/.sops.yaml`

```yaml
creation_rules:
  - path_regex: .+\.sops\.yaml
    encrypted_regex: ^(data|stringData)$
    mac_only_encrypted: true
    key_groups:
      - age:
          - age1kesma5f5dadlzdl5lzgrtxl6e8z8frf7njsfnlnprzan0lmzgdmstnd39u
```

### Working with Secrets

**Encrypt a new secret**:
```bash
sops --age=age1kesma5f5dadlzdl5lzgrtxl6e8z8frf7njsfnlnprzan0lmzgdmstnd39u \
     --encrypt \
     --encrypted-regex '^(data|stringData)$' \
     --in-place path/to/secret.sops.yaml
```

**Edit an encrypted secret**:
```bash
export SOPS_AGE_KEY=AGE-SECRET-KEY-xxxxxx
sops path/to/secret.sops.yaml
```

**Decrypt for viewing**:
```bash
sops -d path/to/secret.sops.yaml
```

### Secret Files in Repository

18 encrypted secret files across:
- Infrastructure: Cloudflare API token, S3 credentials, ingress secrets
- Applications: 14 app-specific secret files
- Cluster: `cluster-secrets.sops.yaml`, `talsecret.sops.yaml`

### Variable Substitution

Secrets become variables via `postBuild.substituteFrom`:

```yaml
postBuild:
  substituteFrom:
    - kind: Secret
      name: cluster-secrets
```

Variables like `${CLUSTER_DOMAIN}`, `${IPV6_PREFIX_GUA}` are substituted at deploy time.

## Validation and CI/CD

### Pre-Commit Hook

Install the pre-commit hook to validate before committing:

```bash
cp scripts/pre-commit .git/hooks/pre-commit
```

To bypass validation: `git commit --no-verify`

### Manual Validation

Run validation scripts from repository root:

```bash
# Validate everything (Talos + Flux)
./scripts/validate.sh

# Validate only Flux/Kubernetes manifests
./scripts/validate.sh flux

# Validate only Talos configurations
./scripts/validate.sh talos
```

### CI/CD Workflows

**validate-flux.yaml** (`/.github/workflows/validate-flux.yaml`)
- Triggers on push with changes to `kubernetes/**`
- Validates YAML syntax with yq
- Validates Kustomize overlays with kubeconform
- Uses strict validation mode

**validate-talos.yaml** (`/.github/workflows/validate-talos.yaml`)
- Triggers on push with changes to `talos/**/*.yaml`
- Validates with `talosctl validate --mode metal --strict`

**gitleaks.yaml** (`/.github/workflows/gitleaks.yaml`)
- Runs on push + daily at 4 AM
- Scans for leaked secrets

## Development Conventions

### Commit Message Convention

Format: `<type>(<scope>): <message> ( <version_change> )`

**Types**:
- `feat!:` - Breaking changes (major version updates)
- `feat:` - New features (minor version updates)
- `fix:` - Bug fixes (patch version updates)
- `chore:` - Maintenance (digest updates)

**Examples**:
```
feat(helm): update chart kube-prometheus-stack ( 80.11.0 ➔ 80.12.0 )
fix(container): update image ghcr.io/esphome/esphome ( 2025.12.4 ➔ 2025.12.5 )
chore(container): update image digest ( abc1234 ➔ def5678 )
```

### File Naming Conventions

- **SOPS files**: Must end with `.sops.yaml`
- **Kustomization files**: `kustomization.yaml`
- **Flux Kustomizations**: `ks.yaml`
- **HelmReleases**: `helmrelease.yaml`
- **HelmRepositories**: `helmrepository.yaml`

### Namespace Convention

- Infrastructure components: Use `kube-system` or component-specific namespaces
- Applications: Organized by category:
  - `home-automation` - Home Assistant, ESPHome, Mosquitto
  - `self-hosted` - Paperless, ChangeDetection
  - `security` - pocket-id (authentication)
  - `media` - Media-related applications

### Labels and Annotations

**Standard Labels**:
```yaml
labels:
  app.kubernetes.io/name: <app-name>
  app.kubernetes.io/instance: <instance-name>
```

**Longhorn Node Labels**:
```yaml
node.longhorn.io/create-default-disk: "true"
```

**Reloader Annotations** (auto-reload on secret/configmap change):
```yaml
annotations:
  reloader.stakater.com/auto: "true"
```

## Common Tasks and Commands

### Talos Operations

**Generate Talos configs** (from talconfig.yaml):
```bash
cd talos/talos1018
talhelper genconfig
```

**Apply config to a node**:
```bash
talosctl apply-config -n 10.18.6.91 --file clusterconfig/talos1018-talos-1018-1.yaml
```

**Get kubeconfig**:
```bash
talosctl kubeconfig --nodes fd00:1018:0:5:10:18:6:90
```

**Upgrade Talos**:
```bash
# Update talconfig.yaml first
talhelper genconfig

TALOS_VERSION=v1.12.1
TALOS_IMAGE="factory.talos.dev/metal-installer/36cd6536eaec8ba802be2d38974108359069cedba8857302f69792b26b87c010:$TALOS_VERSION"

talosctl upgrade -n fd00:1018:0:5:10:18:6:91 --image "$TALOS_IMAGE" --wait
talosctl upgrade -n fd00:1018:0:5:10:18:6:92 --image "$TALOS_IMAGE" --wait
talosctl upgrade -n fd00:1018:0:5:10:18:6:93 --image "$TALOS_IMAGE" --wait
```

### Flux Operations

**Bootstrap Flux** (initial setup):
```bash
export GITHUB_TOKEN="github_pat_xxxxxxxxxxxxxxx"
flux bootstrap github \
  --owner=fmurodov \
  --repository=homeops \
  --branch=master \
  --personal=true \
  --path=kubernetes/clusters/talos1018
```

**Reconcile Flux**:
```bash
flux reconcile kustomization flux-system --with-source
```

**Check Flux status**:
```bash
flux get all -A
```

**Suspend/Resume a Kustomization**:
```bash
flux suspend kustomization <name>
flux resume kustomization <name>
```

### Kubernetes Operations

**Check all resources in a namespace**:
```bash
kubectl get all -n <namespace>
```

**Describe a HelmRelease**:
```bash
kubectl describe helmrelease <name> -n <namespace>
```

**Check logs**:
```bash
kubectl logs -n <namespace> <pod-name>
```

**Get events**:
```bash
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

## Talos Cluster Specifics

### Cluster: talos1018

**Network Configuration**:
- Control plane VIP: `fd00:1018:0:5:10:18:6:90`
- Node IPs: `fd00:1018:0:5:10:18:6:91-93` (IPv6), `10.18.6.91-93` (IPv4)
- Dual-stack IPv4/IPv6
- MTU: 9000 (jumbo frames)
- VLAN 3 for management

**Pod Networks**:
- IPv6: `fd00:1018:1000::/56`
- IPv4: `10.244.0.0/16`

**Service Networks**:
- IPv6: `fd00:1018:2000::/96`
- IPv4: `10.96.0.0/12`

**Nodes**:
- talos-1018-1: Control plane, 500GB+ NVMe
- talos-1018-2: Control plane, 500GB+ NVMe
- talos-1018-3: Control plane, 500GB+ NVMe

All nodes are schedulable (no taints).

### Cilium L2 Announcements

LoadBalancer IP pools:
- **Internal**: `10.18.6.60-10.18.6.69` (10 IPs)
- **External**: `${IPV6_PREFIX_GUA}:6:90-${IPV6_PREFIX_GUA}:6:99` (IPv6)

Configuration: `kubernetes/infrastructure/talos1018/core/cilium/config/`

## Application Deployment Patterns

### HelmRelease Pattern (Most Common)

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <app-name>
  namespace: <namespace>
spec:
  interval: 30m
  chart:
    spec:
      chart: <chart-name>
      version: <version>
      sourceRef:
        kind: HelmRepository
        name: <repo-name>
        namespace: flux-system
  values:
    # Chart values here
  valuesFrom:
    - kind: Secret
      name: <secret-name>
      valuesKey: <key>
```

### Custom Manifest Pattern

For apps without Helm charts:

```
app/
├── deployment.yaml
├── service.yaml
├── configmap.yaml
├── secret.sops.yaml
├── persistentvolumeclaim.yaml
└── kustomization.yaml
```

### app-template Pattern

Many apps use the `bjw-s/app-template` Helm chart for standardized deployments.

## Renovate Dependency Management

Renovate automatically updates:
- Helm charts
- Container images
- Talos versions
- Kubernetes versions
- Flux components
- GitHub Actions

**Configuration**: `.renovaterc.json5` + `.renovate/*.json5`

**Auto-merge Rules**:
- Docker digest updates (patch/minor)
- GitHub Actions (3+ days old)
- Trusted actions (immediate)

**Grouped Updates**:
- Kubernetes components (5+ packages)
- Talos components (2+ packages)
- Flux components (2+ packages)

## Important Notes for AI Assistants

### DO:

1. **Always validate before committing**:
   - Run `./scripts/validate.sh` before creating commits
   - Fix validation errors before pushing

2. **Use semantic commit messages**:
   - Follow the convention: `type(scope): message ( version_change )`
   - Examples provided above

3. **Respect the layered architecture**:
   - Understand dependencies between infra-core, infra-storage, and apps
   - Don't create circular dependencies

4. **Follow the component structure pattern**:
   - Use `app/` and `config/` directories for infrastructure components
   - Create `ks.yaml` for Flux Kustomization definitions

5. **Encrypt secrets with SOPS**:
   - Never commit unencrypted secrets
   - Use `.sops.yaml` suffix for encrypted files
   - Only encrypt `data` and `stringData` fields

6. **Read existing patterns**:
   - Look at existing components for examples
   - Follow the same structure and conventions

7. **Use variable substitution**:
   - Reference cluster-wide variables from `cluster-secrets`
   - Use `${VARIABLE_NAME}` syntax

8. **Test changes**:
   - Validate manifests locally before pushing
   - Use `kubectl apply --dry-run=client` to test

### DON'T:

1. **Don't edit generated files**:
   - Never edit files in `talos/talos1018/clusterconfig/`
   - These are generated by talhelper from `talconfig.yaml`

2. **Don't skip validation**:
   - Always run validation before committing
   - Fix errors, don't ignore them

3. **Don't commit secrets**:
   - Never commit unencrypted secrets
   - Use SOPS encryption for all sensitive data
   - Check with gitleaks before pushing

4. **Don't break dependencies**:
   - Understand the dependency chain before making changes
   - Don't remove infrastructure components that apps depend on

5. **Don't hardcode values**:
   - Use cluster-wide variables from `cluster-secrets`
   - Don't hardcode IPs, domains, or credentials

6. **Don't create monolithic files**:
   - Follow the component structure pattern
   - Split app and config into separate directories

7. **Don't bypass Git hooks**:
   - Use `--no-verify` only when absolutely necessary
   - Fix validation errors instead of bypassing them

8. **Don't modify Flux system files**:
   - Files in `kubernetes/clusters/talos1018/flux-system/` are managed by Flux
   - Use `flux bootstrap` for Flux updates

### When Making Changes:

1. **For new applications**:
   - Create directory structure: `kubernetes/apps/talos1018/<category>/<app-name>/`
   - Follow HelmRelease or custom manifest pattern
   - Add to `kubernetes/apps/talos1018/kustomization.yaml`
   - Encrypt secrets with SOPS

2. **For infrastructure changes**:
   - Understand impact on dependent components
   - Test in non-production first if possible
   - Update documentation in README files

3. **For Talos changes**:
   - Edit `talos/talos1018/talconfig.yaml`
   - Run `talhelper genconfig`
   - Validate with `./scripts/validate.sh talos`
   - Apply to nodes with `talosctl apply-config`

4. **For secret changes**:
   - Edit with `sops <file>.sops.yaml`
   - Verify encryption with `sops -d <file>.sops.yaml`
   - Never commit unencrypted secrets

### Troubleshooting:

1. **HelmRelease not deploying**:
   - Check dependencies in `ks.yaml`
   - Verify HelmRepository is ready: `kubectl get helmrepository -A`
   - Check events: `kubectl describe helmrelease <name> -n <namespace>`

2. **Flux not reconciling**:
   - Check Kustomization status: `flux get kustomizations -A`
   - Check GitRepository: `flux get sources git -A`
   - Force reconcile: `flux reconcile kustomization <name> --with-source`

3. **SOPS decryption errors**:
   - Verify age secret exists: `kubectl get secret sops-age -n flux-system`
   - Check Kustomization has `decryption.secretRef.name: sops-age`

4. **Validation failures**:
   - Read error messages carefully
   - Check YAML syntax with `yq`
   - Validate Kustomize overlays: `kubectl kustomize <path>`

## References

- **Flux Documentation**: https://fluxcd.io/docs/
- **Talos Documentation**: https://www.talos.dev/latest/
- **SOPS Documentation**: https://github.com/mozilla/sops
- **Cilium Documentation**: https://docs.cilium.io/
- **Repository Structure Based On**: https://github.com/fluxcd/flux2-kustomize-helm-example

## Repository Metadata

- **Owner**: fmurodov
- **Repository**: homeops
- **Main Branch**: master
- **Flux Path**: kubernetes/clusters/talos1018
- **Cluster Name**: talos1018
- **Kubernetes Version**: v1.35.0
- **Talos Version**: v1.12.1
- **Cilium Version**: v1.18.5

---

**Last Updated**: 2026-01-06
**Maintainer**: fmurodov

This document should be updated when significant architectural changes are made to the repository.
