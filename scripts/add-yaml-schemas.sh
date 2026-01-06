#!/usr/bin/env bash

# Script to add YAML schemas to files that are missing them
# This script adds appropriate yaml-language-server schema comments to YAML files

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counter
FILES_UPDATED=0
FILES_SKIPPED=0

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if file has yaml-language-server schema
has_schema() {
    local file=$1
    head -n 5 "$file" | grep -q "yaml-language-server"
}

# Function to get the API version and kind from a YAML file
get_resource_info() {
    local file=$1
    local apiVersion=$(yq eval '.apiVersion // ""' "$file" 2>/dev/null | head -1)
    local kind=$(yq eval '.kind // ""' "$file" 2>/dev/null | head -1)
    echo "$apiVersion|$kind"
}

# Function to determine schema URL based on apiVersion and kind
get_schema_url() {
    local apiVersion=$1
    local kind=$2
    local filename=$3

    case "$apiVersion|$kind" in
        "kustomize.toolkit.fluxcd.io/v1"|"Kustomization")
            echo "https://k8s-schemas.bjw-s.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json"
            ;;
        "kustomize.config.k8s.io/v1beta1"|"Kustomization")
            echo "https://json.schemastore.org/kustomization"
            ;;
        "kustomize.config.k8s.io/v1alpha1"|"Component")
            echo "https://json.schemastore.org/kustomization"
            ;;
        "helm.toolkit.fluxcd.io/v2"|"HelmRelease")
            echo "https://k8s-schemas.bjw-s.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json"
            ;;
        "source.toolkit.fluxcd.io/v1"|"HelmRepository")
            echo "https://k8s-schemas.bjw-s.dev/source.toolkit.fluxcd.io/helmrepository_v1.json"
            ;;
        "source.toolkit.fluxcd.io/v1"|"OCIRepository")
            echo "https://k8s-schemas.bjw-s.dev/source.toolkit.fluxcd.io/ocirepository_v1.json"
            ;;
        "source.toolkit.fluxcd.io/v1"|"GitRepository")
            echo "https://k8s-schemas.bjw-s.dev/source.toolkit.fluxcd.io/gitrepository_v1.json"
            ;;
        *)
            # Check if it's a Kubernetes core resource
            if [[ "$kind" =~ ^(Deployment|Service|Ingress|Secret|ConfigMap|Namespace|ServiceAccount|ClusterRole|ClusterRoleBinding|PersistentVolumeClaim|StatefulSet|DaemonSet|CronJob|NetworkPolicy)$ ]]; then
                echo "https://json.schemastore.org/kubernetes"
            # Check if it's a SOPS config file
            elif [[ "$filename" == ".sops.yaml" ]]; then
                echo "https://json.schemastore.org/sops"
            else
                echo ""
            fi
            ;;
    esac
}

# Function to check if file starts with ---
starts_with_separator() {
    local file=$1
    head -n 1 "$file" | grep -q "^---$"
}

# Function to add schema comment to file
add_schema() {
    local file=$1
    local schema_url=$2

    # Create temp file
    local tmpfile=$(mktemp)

    # Check if file starts with ---
    if starts_with_separator "$file"; then
        # Remove the first --- line, add schema comment, then add --- back
        tail -n +2 "$file" > "$tmpfile"
        echo "---" > "$file"
        echo "# yaml-language-server: \$schema=$schema_url" >> "$file"
        cat "$tmpfile" >> "$file"
    else
        # Add --- and schema comment at the beginning
        cat "$file" > "$tmpfile"
        echo "---" > "$file"
        echo "# yaml-language-server: \$schema=$schema_url" >> "$file"
        cat "$tmpfile" >> "$file"
    fi

    rm "$tmpfile"
    log_info "Added schema to: $file"
    ((FILES_UPDATED++))
}

# Function to ensure file starts with ---
ensure_separator() {
    local file=$1

    if ! starts_with_separator "$file"; then
        # Check if it's a schema comment line
        local first_line=$(head -n 1 "$file")
        if [[ "$first_line" == "# yaml-language-server:"* ]]; then
            # Schema is already there, just add --- at the beginning
            local tmpfile=$(mktemp)
            cat "$file" > "$tmpfile"
            echo "---" > "$file"
            cat "$tmpfile" >> "$file"
            rm "$tmpfile"
            log_info "Added --- separator to: $file"
            ((FILES_UPDATED++))
        else
            # No schema, add --- at the beginning
            local tmpfile=$(mktemp)
            cat "$file" > "$tmpfile"
            echo "---" > "$file"
            cat "$tmpfile" >> "$file"
            rm "$tmpfile"
            log_info "Added --- separator to: $file"
            ((FILES_UPDATED++))
        fi
    fi
}

# Process a single file
process_file() {
    local file=$1

    # Skip generated files
    if [[ "$file" =~ clusterconfig/ ]] || [[ "$file" =~ \.git/ ]] || [[ "$file" =~ flux-system/gotk ]]; then
        return
    fi

    # Skip files that already have schema
    if has_schema "$file"; then
        # Still check if it starts with ---
        if ! starts_with_separator "$file"; then
            ensure_separator "$file"
        else
            ((FILES_SKIPPED++))
        fi
        return
    fi

    # Get resource info
    local info=$(get_resource_info "$file")
    local apiVersion=$(echo "$info" | cut -d'|' -f1)
    local kind=$(echo "$info" | cut -d'|' -f2)
    local filename=$(basename "$file")

    # Skip if no apiVersion/kind (might be values.yaml or other config)
    if [[ -z "$apiVersion" ]] || [[ -z "$kind" ]]; then
        # Special case for .sops.yaml files
        if [[ "$filename" == ".sops.yaml" ]]; then
            local schema_url="https://json.schemastore.org/sops"
            add_schema "$file" "$schema_url"
            return
        fi
        # Otherwise just ensure it starts with ---
        if ! starts_with_separator "$file"; then
            ensure_separator "$file"
        else
            ((FILES_SKIPPED++))
        fi
        return
    fi

    # Get schema URL
    local schema_url=$(get_schema_url "$apiVersion" "$kind" "$filename")

    if [[ -n "$schema_url" ]]; then
        add_schema "$file" "$schema_url"
    else
        log_warn "No schema mapping for: $file (apiVersion: $apiVersion, kind: $kind)"
        # Still ensure it starts with ---
        if ! starts_with_separator "$file"; then
            ensure_separator "$file"
        else
            ((FILES_SKIPPED++))
        fi
    fi
}

# Main execution
main() {
    log_info "Starting YAML schema addition..."

    # Check if yq is installed
    if ! command -v yq &> /dev/null; then
        log_error "yq is required but not installed. Please install yq."
        exit 1
    fi

    # Find all YAML files in kubernetes/ directory
    while IFS= read -r file; do
        process_file "$file"
    done < <(find kubernetes/ -name "*.yaml" -type f)

    # Find all YAML files in talos/ directory (excluding clusterconfig/)
    while IFS= read -r file; do
        process_file "$file"
    done < <(find talos/talos1018/ -name "*.yaml" -type f | grep -v "clusterconfig/")

    log_info "Schema addition complete!"
    log_info "Files updated: $FILES_UPDATED"
    log_info "Files skipped (already have schema): $FILES_SKIPPED"
}

main
