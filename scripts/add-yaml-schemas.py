#!/usr/bin/env python3
"""
Script to add YAML schemas to files that are missing them.
This script adds appropriate yaml-language-server schema comments to YAML files.
"""

import os
import re
import sys
from pathlib import Path
from typing import Optional, Tuple

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(1)


class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    NC = '\033[0m'  # No Color


def log_info(msg: str):
    print(f"{Colors.GREEN}[INFO]{Colors.NC} {msg}")


def log_warn(msg: str):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")


def log_error(msg: str):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}")


def has_schema(file_path: Path) -> bool:
    """Check if file has yaml-language-server schema comment."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            # Read first 5 lines
            for _ in range(5):
                line = f.readline()
                if not line:
                    break
                if 'yaml-language-server' in line:
                    return True
    except Exception as e:
        log_error(f"Error reading {file_path}: {e}")
    return False


def starts_with_separator(file_path: Path) -> bool:
    """Check if file starts with ---"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            first_line = f.readline().strip()
            return first_line == '---'
    except Exception as e:
        log_error(f"Error reading {file_path}: {e}")
        return False


def get_resource_info(file_path: Path) -> Tuple[Optional[str], Optional[str]]:
    """Get apiVersion and kind from YAML file."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            # Load first document only
            doc = yaml.safe_load(f)
            if doc and isinstance(doc, dict):
                api_version = doc.get('apiVersion')
                kind = doc.get('kind')
                return api_version, kind
    except yaml.YAMLError as e:
        # Might be a SOPS encrypted file or multi-doc, that's okay
        pass
    except Exception as e:
        log_error(f"Error parsing {file_path}: {e}")
    return None, None


def get_schema_url(api_version: Optional[str], kind: Optional[str], filename: str) -> Optional[str]:
    """Determine schema URL based on apiVersion and kind."""
    if not api_version or not kind:
        # Special case for .sops.yaml files
        if filename == '.sops.yaml':
            return 'https://json.schemastore.org/sops'
        return None

    # Flux Kustomization
    if api_version == 'kustomize.toolkit.fluxcd.io/v1' and kind == 'Kustomization':
        return 'https://k8s-schemas.bjw-s.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json'

    # Kustomize Kustomization
    if api_version == 'kustomize.config.k8s.io/v1beta1' and kind == 'Kustomization':
        return 'https://json.schemastore.org/kustomization'

    # Kustomize Component
    if api_version == 'kustomize.config.k8s.io/v1alpha1' and kind == 'Component':
        return 'https://json.schemastore.org/kustomization'

    # Flux HelmRelease
    if api_version == 'helm.toolkit.fluxcd.io/v2' and kind == 'HelmRelease':
        return 'https://k8s-schemas.bjw-s.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json'

    # Flux HelmRepository
    if api_version == 'source.toolkit.fluxcd.io/v1' and kind == 'HelmRepository':
        return 'https://k8s-schemas.bjw-s.dev/source.toolkit.fluxcd.io/helmrepository_v1.json'

    # Flux OCIRepository
    if api_version == 'source.toolkit.fluxcd.io/v1' and kind == 'OCIRepository':
        return 'https://k8s-schemas.bjw-s.dev/source.toolkit.fluxcd.io/ocirepository_v1.json'

    # Flux GitRepository
    if api_version == 'source.toolkit.fluxcd.io/v1' and kind == 'GitRepository':
        return 'https://k8s-schemas.bjw-s.dev/source.toolkit.fluxcd.io/gitrepository_v1.json'

    # Kubernetes core resources
    k8s_core_kinds = [
        'Deployment', 'Service', 'Ingress', 'Secret', 'ConfigMap', 'Namespace',
        'ServiceAccount', 'ClusterRole', 'ClusterRoleBinding', 'Role', 'RoleBinding',
        'PersistentVolumeClaim', 'PersistentVolume', 'StatefulSet', 'DaemonSet',
        'CronJob', 'Job', 'NetworkPolicy', 'ResourceQuota', 'LimitRange'
    ]
    if kind in k8s_core_kinds:
        return 'https://json.schemastore.org/kubernetes'

    return None


def add_schema_to_file(file_path: Path, schema_url: str) -> bool:
    """Add schema comment to file."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Check if file starts with ---
        lines = content.split('\n')
        schema_comment = f'# yaml-language-server: $schema={schema_url}'

        if lines[0].strip() == '---':
            # Insert schema comment after ---
            new_content = lines[0] + '\n' + schema_comment + '\n' + '\n'.join(lines[1:])
        else:
            # Add --- and schema comment at the beginning
            new_content = '---\n' + schema_comment + '\n' + content

        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)

        return True
    except Exception as e:
        log_error(f"Error writing to {file_path}: {e}")
        return False


def ensure_separator(file_path: Path) -> bool:
    """Ensure file starts with ---"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()

        if not content.strip().startswith('---'):
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write('---\n' + content)
            return True
    except Exception as e:
        log_error(f"Error processing {file_path}: {e}")
    return False


def should_skip_file(file_path: Path) -> bool:
    """Check if file should be skipped."""
    path_str = str(file_path)

    # Skip patterns
    skip_patterns = [
        'clusterconfig/',
        '.git/',
        'flux-system/gotk',
        'values.yaml',  # Helm values files don't need schemas
    ]

    for pattern in skip_patterns:
        if pattern in path_str:
            return True

    return False


def process_file(file_path: Path, stats: dict):
    """Process a single YAML file."""
    if should_skip_file(file_path):
        stats['skipped'] += 1
        return

    # Check if already has schema
    if has_schema(file_path):
        # Still check if it starts with ---
        if not starts_with_separator(file_path):
            if ensure_separator(file_path):
                log_info(f"Added --- separator to: {file_path}")
                stats['updated'] += 1
            else:
                stats['skipped'] += 1
        else:
            stats['skipped'] += 1
        return

    # Get resource info
    api_version, kind = get_resource_info(file_path)
    filename = file_path.name

    # Get schema URL
    schema_url = get_schema_url(api_version, kind, filename)

    if schema_url:
        if add_schema_to_file(file_path, schema_url):
            log_info(f"Added schema to: {file_path}")
            stats['updated'] += 1
        else:
            stats['errors'] += 1
    else:
        # No schema mapping found, just ensure it starts with ---
        if api_version and kind:
            log_warn(f"No schema mapping for: {file_path} (apiVersion: {api_version}, kind: {kind})")

        if not starts_with_separator(file_path):
            if ensure_separator(file_path):
                log_info(f"Added --- separator to: {file_path}")
                stats['updated'] += 1
            else:
                stats['no_schema'] += 1
        else:
            stats['no_schema'] += 1


def main():
    log_info("Starting YAML schema addition...")

    repo_root = Path(__file__).parent.parent
    stats = {
        'updated': 0,
        'skipped': 0,
        'errors': 0,
        'no_schema': 0,
    }

    # Process kubernetes/ directory
    kubernetes_dir = repo_root / 'kubernetes'
    if kubernetes_dir.exists():
        for yaml_file in kubernetes_dir.rglob('*.yaml'):
            process_file(yaml_file, stats)

    # Process talos/ directory (excluding clusterconfig/)
    talos_dir = repo_root / 'talos' / 'talos1018'
    if talos_dir.exists():
        for yaml_file in talos_dir.rglob('*.yaml'):
            if 'clusterconfig' not in str(yaml_file):
                process_file(yaml_file, stats)

    log_info("\n=== Summary ===")
    log_info(f"Files updated: {stats['updated']}")
    log_info(f"Files skipped (already have schema): {stats['skipped']}")
    log_info(f"Files without schema mapping: {stats['no_schema']}")
    log_info(f"Errors: {stats['errors']}")


if __name__ == '__main__':
    main()
