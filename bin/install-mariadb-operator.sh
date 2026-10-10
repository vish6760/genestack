#!/bin/bash
# Description: Fetches the version for SERVICE_NAME_DEFAULT from the specified
# YAML file and executes a helm upgrade/install command with dynamic values files.

# Disable SC2124 (unused array), SC2145 (array expansion issue), SC2294 (eval)
# shellcheck disable=SC2124,SC2145,SC2294

# Service
SERVICE_NAME_DEFAULT="mariadb-operator"
CRDS_NAME_DEFAULT="mariadb-operator-crds"
SERVICE_NAMESPACE="mariadb-system"

# Base directories provided by the environment
GENESTACK_BASE_DIR="${GENESTACK_BASE_DIR:-/opt/genestack}"
GENESTACK_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR:-/etc/genestack}"

# Common secret helpers. Missing secrets are generated in Kubernetes and
# existing secrets are never overwritten.
# shellcheck source=helpers.sh
source "${GENESTACK_BASE_DIR}/bin/helpers.sh"
trap cleanup_tmp EXIT

# Custom values directory is used for generated clusterName overrides.
SERVICE_CUSTOM_OVERRIDES="${GENESTACK_OVERRIDES_DIR}/helm-configs/${SERVICE_NAME_DEFAULT}"

# Read the desired chart version from VERSION_FILE
VERSION_FILE="${GENESTACK_OVERRIDES_DIR}/helm-chart-versions.yaml"

if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: helm-chart-versions.yaml not found at $VERSION_FILE" >&2
    exit 1
fi

# Extract version dynamically using the SERVICE_NAME_DEFAULT variable
SERVICE_VERSION=$(grep "^[[:space:]]*${SERVICE_NAME_DEFAULT}:" "$VERSION_FILE" | sed "s/.*${SERVICE_NAME_DEFAULT}: *//")

if [ -z "$SERVICE_VERSION" ]; then
    echo "Error: Could not extract version for '$SERVICE_NAME_DEFAULT' from $VERSION_FILE" >&2
    exit 1
fi

echo "Found version for $SERVICE_NAME_DEFAULT: $SERVICE_VERSION"

# Default parameter value
export CLUSTER_NAME=${CLUSTER_NAME:-cluster.local}

# 'cluster.local' is the default value in base helm values file
if [ "${CLUSTER_NAME}" != "cluster.local" ]; then
    SERVICE_CONFIG_FILE="$SERVICE_CUSTOM_OVERRIDES/mariadb-operator-helm-overrides.yaml"
    touch "$SERVICE_CONFIG_FILE"
    # Check if the file is empty and add/modify content accordingly
    if [ ! -s "$SERVICE_CONFIG_FILE" ]; then
        echo "clusterName: $CLUSTER_NAME" > "$SERVICE_CONFIG_FILE"
    else
        # If the clusterName line exists, modify it, otherwise add it at the end
        if grep -q "^clusterName:" "$SERVICE_CONFIG_FILE"; then
            sed -i -e "s/^clusterName: .*/clusterName: ${CLUSTER_NAME}/" "$SERVICE_CONFIG_FILE"
        else
            echo "clusterName: $CLUSTER_NAME" >> "$SERVICE_CONFIG_FILE"
        fi
    fi
fi

# The CRD chart is a sibling of the operator chart in the same repository.
SERVICE_CONFIG=$(load_service_config "$SERVICE_NAME_DEFAULT") || exit 1
CRDS_NAME=$(yq e '.chart.service_crds // .crd_chart // ""' - <<< "$SERVICE_CONFIG") || exit 1
if [[ -z "$CRDS_NAME" ]]; then
    echo "Error: Missing CRD chart name for $SERVICE_NAME_DEFAULT" >&2
    exit 1
fi

resolve_service_chart "$SERVICE_NAME_DEFAULT" || exit 1
CRDS_CHART_PATH="${HELM_CHART_PATH%/*}/${CRDS_NAME}"
if [[ "$CRDS_CHART_PATH" == /* && ! -d "$CRDS_CHART_PATH" ]]; then
    echo "Error: Local CRD chart not found at $CRDS_CHART_PATH" >&2
    exit 1
fi

build_helm_args "$SERVICE_NAME_DEFAULT" || exit 1

# Collect all --set arguments, executing commands and quoting safely
# Collect secret-backed --set arguments from bin/services/${SERVICE_NAME_DEFAULT}.yaml.
collect_service_secret_set_args "$SERVICE_NAME_DEFAULT"
set_args=("${SECRET_HELM_SET_ARGS[@]}")

# Install the CRDs that match the version defined
helm upgrade --install --namespace="$SERVICE_NAMESPACE" --create-namespace "$CRDS_NAME_DEFAULT" "$CRDS_CHART_PATH" --version "${SERVICE_VERSION}"

helm_command=(
    helm upgrade --install "$SERVICE_NAME_DEFAULT" "$HELM_CHART_PATH"
    --version "${SERVICE_VERSION}"
    --namespace="$SERVICE_NAMESPACE"
    --timeout 120m

    "${overrides_args[@]}"
    "${set_args[@]}"

    # Post-renderer configuration
    --post-renderer "$GENESTACK_OVERRIDES_DIR/kustomize/kustomize.sh"
    --post-renderer-args "$SERVICE_NAME_DEFAULT/overlay"

    "$@"
)

echo "Executing Helm command (arguments are quoted safely):"
printf '%q ' "${helm_command[@]}"
echo

# Execute the command directly from the array
"${helm_command[@]}"
