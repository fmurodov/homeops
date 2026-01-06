# CLAUDE.md - AI Assistant Guide for HomeOps

This document provides essential guidance for AI assistants working with this Infrastructure as Code (IaC) repository.

## Repository Overview

**HomeOps** manages a home Kubernetes cluster using:
- **Talos Linux** - Immutable Kubernetes OS (3-node cluster: talos1018)
- **Flux CD** - GitOps continuous deployment
- **SOPS + age** - Secret encryption
- **Renovate** - Automated dependency updates

**Main Branch**: `master`
**Repository**: https://github.com/fmurodov/homeops

> **Version Info**: Check `talos/talos1018/talconfig.yaml` for Kubernetes/Talos versions, HelmRelease files for application versions.

## Directory Structure

```
homeops/
├── talos/talos1018/           # Talos cluster config
│   ├── talconfig.yaml         # Source of truth (edit this)
│   └── clusterconfig/         # Generated configs (DO NOT EDIT)
│
├── kubernetes/
│   ├── clusters/talos1018/    # Flux configuration
│   │   ├── cluster-config.yaml      # Cluster secrets/vars
│   │   ├── infrastructure.yaml      # Infrastructure layer
│   │   └── apps.yaml               # Applications layer
│   ├── infrastructure/talos1018/
│   │   ├── core/              # Cilium, cert-manager, ingress-nginx
│   │   └── storage/           # Longhorn
│   ├── apps/talos1018/        # 20+ applications
│   └── components/common/     # Shared components (cluster-secrets)
│
├── scripts/
│   ├── validate.sh            # Master validation script
│   └── pre-commit             # Git pre-commit hook
│
└── .github/workflows/         # CI/CD validation
```

## GitOps Architecture

**Layered Dependency Model**:
```
cluster-config (secrets/vars)
    ↓
infra-core (Cilium, cert-manager, ingress-nginx)
    ↓
infra-storage (Longhorn)
    ↓
applications (20+ apps, deploy in parallel)
```

**Component Structure** (infrastructure components):
```
component/
├── app/                 # HelmRelease + HelmRepository
├── config/              # CRDs, custom resources
└── ks.yaml             # Flux Kustomization orchestration
```

## Secret Management

All secrets use **SOPS + age** encryption.

**Encryption rules** (`kubernetes/.sops.yaml`, `talos/talos1018/.sops.yaml`):
- Files must end with `.sops.yaml`
- Only `data` and `stringData` fields are encrypted
- Age key: `age1kesma5f5dadlzdl5lzgrtxl6e8z8frf7njsfnlnprzan0lmzgdmstnd39u`

**Variable substitution** - Secrets become cluster-wide variables:
```yaml
postBuild:
  substituteFrom:
    - kind: Secret
      name: cluster-secrets
```

Use `${CLUSTER_DOMAIN}`, `${IPV6_PREFIX_GUA}`, etc. in manifests.

## Development Workflow

### Validation (Required Before Commits)

```bash
# Install pre-commit hook (recommended)
cp scripts/pre-commit .git/hooks/pre-commit

# Manual validation
./scripts/validate.sh        # Validate everything
./scripts/validate.sh flux   # Kubernetes manifests only
./scripts/validate.sh talos  # Talos configs only
```

**CI/CD**: GitHub Actions automatically validate on push.

### Commit Message Convention

Format: `<type>(<scope>): <message> ( <version_change> )`

**Types**:
- `feat!:` - Breaking changes (major)
- `feat:` - New features (minor)
- `fix:` - Bug fixes (patch)
- `chore:` - Maintenance (digests)

**Examples**:
```
feat(helm): update chart kube-prometheus-stack ( 80.11.0 ➔ 80.12.0 )
fix(container): update image ghcr.io/esphome/esphome ( 2025.12.4 ➔ 2025.12.5 )
```

## Critical Rules for AI Assistants

### ✅ DO:

1. **Always validate before committing** - Run `./scripts/validate.sh`
2. **Follow semantic commits** - Use the convention above
3. **Encrypt all secrets** - Use SOPS, never commit unencrypted secrets
4. **Respect layered architecture** - Understand infra-core → infra-storage → apps dependencies
5. **Follow existing patterns** - Look at similar components for examples
6. **Use variable substitution** - Reference `${CLUSTER_DOMAIN}`, etc. from cluster-secrets

### ❌ DON'T:

1. **Don't edit generated files** - Never touch `talos/talos1018/clusterconfig/*`
2. **Don't commit unencrypted secrets** - All secrets must use `.sops.yaml` suffix and be encrypted
3. **Don't skip validation** - Always run validation, fix errors instead of bypassing
4. **Don't hardcode values** - Use cluster-wide variables instead of IPs/domains
5. **Don't modify Flux system files** - Files in `kubernetes/clusters/talos1018/flux-system/` are Flux-managed
6. **Don't break dependencies** - Check Flux Kustomization dependencies before changes

## Common Tasks

### Talos Configuration Changes

```bash
# 1. Edit talos/talos1018/talconfig.yaml
# 2. Regenerate configs
cd talos/talos1018 && talhelper genconfig
# 3. Validate
./scripts/validate.sh talos
# 4. Apply to nodes
talosctl apply-config -n <node-ip> --file clusterconfig/<config>.yaml
```

### Adding New Applications

```bash
# 1. Create directory structure
kubernetes/apps/talos1018/<category>/<app-name>/
├── helmrelease.yaml (or custom manifests)
├── secret.sops.yaml (if needed)
└── kustomization.yaml

# 2. Encrypt secrets
sops --age=age1kesma5f5dadlzdl5lzgrtxl6e8z8frf7njsfnlnprzan0lmzgdmstnd39u \
     --encrypt --encrypted-regex '^(data|stringData)$' \
     --in-place secret.sops.yaml

# 3. Add to kubernetes/apps/talos1018/kustomization.yaml
# 4. Validate before commit
./scripts/validate.sh flux
```

### Working with Secrets

```bash
# Edit encrypted secret
export SOPS_AGE_KEY=AGE-SECRET-KEY-xxxxxx
sops path/to/secret.sops.yaml

# View decrypted secret
sops -d path/to/secret.sops.yaml
```

## Troubleshooting

**HelmRelease not deploying**:
- Check dependencies in component's `ks.yaml`
- `kubectl get helmrepository -A` - verify repo is ready
- `kubectl describe helmrelease <name> -n <namespace>` - check events

**Flux not reconciling**:
- `flux get kustomizations -A` - check status
- `flux reconcile kustomization <name> --with-source` - force reconcile

**SOPS decryption errors**:
- Verify age secret exists: `kubectl get secret sops-age -n flux-system`
- Check Kustomization has `decryption.secretRef.name: sops-age`

**Validation failures**:
- Read error messages carefully
- Check YAML syntax: `yq eval path/to/file.yaml`
- Validate Kustomize: `kubectl kustomize path/to/overlay`

## Key File Locations

- **Cluster-wide secrets**: `kubernetes/components/common/cluster-secrets.sops.yaml`
- **Talos config**: `talos/talos1018/talconfig.yaml`
- **Flux orchestration**: `kubernetes/clusters/talos1018/{cluster-config,infrastructure,apps}.yaml`
- **SOPS config**: `kubernetes/.sops.yaml`, `talos/talos1018/.sops.yaml`
- **Validation scripts**: `scripts/validate.sh`, `scripts/validate-flux.sh`

## Additional Resources

- **Detailed READMEs**: Check component-specific README files for detailed setup
  - `talos/talos1018/README.md` - Talos cluster setup
  - `kubernetes/README.md` - Flux bootstrap and secret management
  - `kubernetes/infrastructure/talos1018/core/cilium/README.md` - Cilium L2 config
- **Flux Documentation**: https://fluxcd.io/docs/
- **Talos Documentation**: https://www.talos.dev/latest/
- **SOPS Documentation**: https://github.com/mozilla/sops

---

**Maintainer**: fmurodov
**Cluster**: talos1018 (3-node control plane, dual-stack IPv4/IPv6)

This document should be updated when significant architectural changes are made to the repository.
