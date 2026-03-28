#!/usr/bin/env bash

# Flux/Kubernetes manifest validation script
# This script downloads the Flux OpenAPI schemas, then it validates the
# Flux custom resources and the kustomize overlays using kubeconform.

# Copyright 2023 The Flux authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Prerequisites
# - yq v4.34
# - kustomize v5.3
# - kubeconform v0.6

set -o errexit
set -o pipefail

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Validating Flux/Kubernetes Manifests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Change to kubernetes directory
cd "$(git rev-parse --show-toplevel)/kubernetes" || exit 1

# mirror kustomize-controller build options
kustomize_flags=("--load-restrictor=LoadRestrictionsNone")
kustomize_config="kustomization.yaml"

# skip Kubernetes Secrets due to SOPS fields failing validation
kubeconform_flags=("-skip=Secret")
kubeconform_config=("-strict" "-ignore-missing-schemas" "-schema-location" "default" "-schema-location" "/tmp/flux-crd-schemas" "-verbose")

# Run yamllint if available
if command -v yamllint &> /dev/null; then
    echo "INFO - Running yamllint"
    cd "$(git rev-parse --show-toplevel)" || exit 1
    if ! yamllint -c .yamllint.yaml kubernetes/ talos/; then
        echo "❌ yamllint found errors"
        exit 1
    fi
    echo "✅ yamllint passed"
    echo ""
    cd "$(git rev-parse --show-toplevel)/kubernetes" || exit 1
else
    echo "INFO - yamllint not found, skipping lint"
fi

echo "INFO - Downloading Flux OpenAPI schemas"
mkdir -p /tmp/flux-crd-schemas/master-standalone-strict
curl -sL https://github.com/fluxcd/flux2/releases/latest/download/crd-schemas.tar.gz | tar zxf - -C /tmp/flux-crd-schemas/master-standalone-strict

find . -type f -name '*.yaml' -print0 | while IFS= read -r -d $'\0' file;
  do
    echo "INFO - Validating $file"
    yq e 'true' "$file" > /dev/null
done

echo "INFO - Validating clusters"
find ./clusters -maxdepth 2 -type f -name '*.yaml' -print0 | while IFS= read -r -d $'\0' file;
  do
    kubeconform "${kubeconform_flags[@]}" "${kubeconform_config[@]}" "${file}"
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
      exit 1
    fi
done

echo "INFO - Validating kustomize overlays"
find . -type f -name $kustomize_config -print0 | while IFS= read -r -d $'\0' file;
  do
    echo "INFO - Validating kustomization ${file/%$kustomize_config}"
    kustomize build "${file/%$kustomize_config}" "${kustomize_flags[@]}" | \
      kubeconform "${kubeconform_flags[@]}" "${kubeconform_config[@]}"
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
      exit 1
    fi
done

# Check for duplicate resources across leaf kustomizations (app/ directories only)
echo "INFO - Checking for duplicate resources across app kustomizations"
DUPES_FILE=$(mktemp)
find . -path "*/app/$kustomize_config" -o -path "*/config/$kustomize_config" -o -path "*/networks/$kustomize_config" | \
  while IFS= read -r file; do
    kustomize build "${file/%$kustomize_config}" "${kustomize_flags[@]}" 2>/dev/null | \
      yq e -N '[.kind, .metadata.name, .metadata.namespace // "default"] | join("/")' - 2>/dev/null
done | sort | uniq -d > "$DUPES_FILE"

if [ -s "$DUPES_FILE" ]; then
    echo "❌ Duplicate resources found across kustomizations:"
    cat "$DUPES_FILE" | sed 's/^/  - /'
    rm -f "$DUPES_FILE"
    exit 1
fi
rm -f "$DUPES_FILE"
echo "✅ No duplicate resources found"

echo ""
echo "✅ All Flux/Kubernetes manifests are valid!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
