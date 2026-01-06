# Pull Request: Add YAML Schemas and Ensure Consistent Formatting

**Branch**: `claude/add-yaml-schemas-7uwhA`
**Base**: `master`

**Quick Link**: https://github.com/fmurodov/homeops/pull/new/claude/add-yaml-schemas-7uwhA

---

## Title

```
feat: add YAML schemas and ensure consistent formatting
```

## Description

### Summary

This PR adds YAML schema comments to all applicable YAML files in the repository and ensures consistent formatting across all files.

### Changes Made

- ✅ Added `yaml-language-server` schema comments to **197+ YAML files**
- ✅ Ensured all YAML files start with `---` separator
- ✅ Created helper scripts for schema management

### Schema Mappings Added

| Resource Type | Schema URL | Count |
|--------------|------------|-------|
| Flux Kustomization | `https://k8s-schemas.bjw-s.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json` | 83 |
| HelmRelease | `https://k8s-schemas.bjw-s.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json` | 13 |
| HelmRepository | `https://k8s-schemas.bjw-s.dev/source.toolkit.fluxcd.io/helmrepository_v1.json` | 7 |
| OCIRepository | `https://k8s-schemas.bjw-s.dev/source.toolkit.fluxcd.io/ocirepository_v1.json` | 4 |
| GitRepository | `https://k8s-schemas.bjw-s.dev/source.toolkit.fluxcd.io/gitrepository_v1.json` | 1 |
| Kustomize Kustomization | `https://json.schemastore.org/kustomization` | Multiple |
| Kubernetes Core Resources | `https://json.schemastore.org/kubernetes` | 100+ |
| SOPS Config | `https://json.schemastore.org/sops` | 2 |

### Benefits

- 🎯 **Improved IDE Support**: Better autocomplete, validation, and inline documentation in VS Code, IntelliJ, and other editors
- ✅ **Early Error Detection**: Catch configuration errors before deployment
- 📚 **Better Developer Experience**: Schema-based documentation right in the editor
- 🔒 **Type Safety**: Validation against official schemas helps prevent misconfigurations

### Files Not Included

Some files don't have public schemas available and were intentionally excluded:
- Cilium CRDs (CiliumLoadBalancerIPPool, CiliumL2AnnouncementPolicy)
- Longhorn CRDs (RecurringJob)
- cert-manager CRDs (ClusterIssuer)
- Custom CRDs (NetworkAttachmentDefinition, etc.)
- Helm values files (values.yaml)

### Helper Scripts Added

- `scripts/add-yaml-schemas.py` - Python script for bulk schema addition
- `scripts/add-yaml-schemas.sh` - Bash script for schema management

### Testing

- ✅ YAML syntax validation passed for all modified files
- ✅ All files maintain proper formatting
- ✅ No changes to actual resource definitions, only metadata comments

### Follow CLAUDE.md Guidelines

- ✅ All secrets remain encrypted with SOPS
- ✅ No generated files modified (excluded `clusterconfig/`)
- ✅ Follows existing patterns and conventions
- ✅ Semantic commit message format used

## Review Checklist

- [ ] All YAML files have appropriate schemas
- [ ] Files start with `---` separator
- [ ] No breaking changes to resource definitions
- [ ] Scripts are useful for future maintenance

---

## Stats

- **Files Modified**: 197 YAML files + 2 helper scripts
- **Total Insertions**: 719 lines (schema comments + separators)
- **Commit**: 3e4a29e
- **Branch**: claude/add-yaml-schemas-7uwhA

## Example Changes

### Before
```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cilium
```

### After
```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.bjw-s.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cilium
```

---

**Ready to create the PR at**: https://github.com/fmurodov/homeops/pull/new/claude/add-yaml-schemas-7uwhA
