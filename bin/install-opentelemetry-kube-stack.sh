#!/bin/bash
# Description: Fetches the version for SERVICE_NAME_DEFAULT from the specified
# YAML file and executes a helm upgrade/install command with dynamic values files.

# Disable SC2124 (unused array), SC2145 (array expansion issue), SC2294 (eval)
# shellcheck disable=SC2124,SC2145,SC2294

# Service
SERVICE_NAME_DEFAULT="opentelemetry-kube-stack"
SERVICE_NAMESPACE="monitoring"

source "$(dirname "$0")/monitoring-common.sh"

# Base directories provided by the environment
GENESTACK_BASE_DIR="${GENESTACK_BASE_DIR:-/opt/genestack}"
GENESTACK_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR:-/etc/genestack}"

# Common secret helpers. Missing secrets are generated in Kubernetes and
# existing secrets are never overwritten.
# shellcheck source=helpers.sh
source "${GENESTACK_BASE_DIR}/bin/helpers.sh"
trap cleanup_tmp EXIT

monitoring_ensure_namespace "${SERVICE_NAMESPACE}"
monitoring_label_namespace_for_talos "${SERVICE_NAMESPACE}"
monitoring_ensure_mariadb_monitoring_secret
monitoring_ensure_rabbitmq_monitoring_secret
monitoring_ensure_postgres_monitoring_secret

adopt_existing_resources_for_helm() {
    local manifest_file="$1"
    local resources

    resources="$(kubectl -n openstack get -f "${manifest_file}" -o name 2>/dev/null || true)"
    if [[ -z "${resources}" ]]; then
        return 0
    fi

    while IFS= read -r resource; do
        [[ -n "${resource}" ]] || continue
        kubectl -n openstack label --overwrite "${resource}" app.kubernetes.io/managed-by=Helm >/dev/null
        kubectl -n openstack annotate --overwrite "${resource}" \
            meta.helm.sh/release-name="${SERVICE_NAME_DEFAULT}" \
            meta.helm.sh/release-namespace="${SERVICE_NAMESPACE}" >/dev/null
    done <<< "${resources}"
}

adopt_existing_resources_for_helm "${GENESTACK_BASE_DIR}/base-kustomize/${SERVICE_NAME_DEFAULT}/base/mariadb-monitoring-user-create.yaml"
adopt_existing_resources_for_helm "${GENESTACK_BASE_DIR}/base-kustomize/${SERVICE_NAME_DEFAULT}/base/mariadb-monitoring-user-grant.yaml"
adopt_existing_resources_for_helm "${GENESTACK_BASE_DIR}/base-kustomize/${SERVICE_NAME_DEFAULT}/base/rabbitmq-monitoring-user-create.yaml"
adopt_existing_resources_for_helm "${GENESTACK_BASE_DIR}/base-kustomize/${SERVICE_NAME_DEFAULT}/base/rabbitmq-monitoring-user-grant.yaml"

# Read the desired chart version from VERSION_FILE
VERSION_FILE="${GENESTACK_OVERRIDES_DIR}/helm-chart-versions.yaml"
FALLBACK_VERSION_FILE="${GENESTACK_BASE_DIR}/helm-chart-versions.yaml"

extract_service_version() {
    local version_file="$1"

    [[ -f "${version_file}" ]] || return 0
    grep "^[[:space:]]*${SERVICE_NAME_DEFAULT}:" "${version_file}" | sed "s/.*${SERVICE_NAME_DEFAULT}: *//" || true
}

if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: helm-chart-versions.yaml not found at $VERSION_FILE" >&2
    exit 1
fi

SERVICE_VERSION="$(extract_service_version "${VERSION_FILE}")"

if [[ -z "${SERVICE_VERSION}" && "${FALLBACK_VERSION_FILE}" != "${VERSION_FILE}" ]]; then
    SERVICE_VERSION="$(extract_service_version "${FALLBACK_VERSION_FILE}")"
    if [[ -n "${SERVICE_VERSION}" ]]; then
        echo "Warning: ${SERVICE_NAME_DEFAULT} is missing from ${VERSION_FILE}; using ${FALLBACK_VERSION_FILE} instead." >&2
    fi
fi

if [ -z "$SERVICE_VERSION" ]; then
    echo "Error: Could not extract version for '$SERVICE_NAME_DEFAULT' from ${VERSION_FILE} or ${FALLBACK_VERSION_FILE}" >&2
    exit 1
fi

echo "Found version for $SERVICE_NAME_DEFAULT: $SERVICE_VERSION"

resolve_service_chart "$SERVICE_NAME_DEFAULT" || exit 1

build_helm_args "$SERVICE_NAME_DEFAULT" || exit 1

# Collect all --set arguments, executing commands and quoting safely
# Collect secret-backed --set arguments from bin/services/${SERVICE_NAME_DEFAULT}.yaml.
collect_service_secret_set_args "$SERVICE_NAME_DEFAULT"
set_args=("${SECRET_HELM_SET_ARGS[@]}")


helm_command=(
    helm upgrade --install "$SERVICE_NAME_DEFAULT" "$HELM_CHART_PATH"
    --version "${SERVICE_VERSION}"
    --namespace="$SERVICE_NAMESPACE"
    --timeout 120m
    --create-namespace

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
