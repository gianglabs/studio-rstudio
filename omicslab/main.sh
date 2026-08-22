#!/bin/bash
set -euo pipefail

R_VERSION="${r_version:-4.4.2}"
DOCKER_IMAGE="docker.io/rocker/rstudio:${R_VERSION}"
CONTAINER_NAME="rstudio-server"
PORT="${PORT:-8787}"

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RSTUDIO_WORKSPACE="$HOME/rstudio-workspace"
mkdir -p "$RSTUDIO_WORKSPACE"

# --- Podman auto-configuration ---
# Find podman binary (via pixi or system) and derive helper paths.
PODMAN_BIN="$(which podman)"
PODMAN_ENV_DIR="$(dirname "$(dirname "$PODMAN_BIN")")"

# Auto-detect network backend: podman 5.x uses netavark, older uses cni.
if [ -f "$PODMAN_ENV_DIR/lib/podman/netavark" ]; then
    NET_BACKEND="netavark"
    CNI_HELPERS=""
else
    NET_BACKEND="cni"
    CNI_HELPERS=",
    \"${PODMAN_ENV_DIR}/lib/cni\""
fi

# Write containers.conf inside the pixi env (gitignored, no host leftovers).
CONTAINERS_CONF="${PODMAN_ENV_DIR}/etc/containers/containers.conf"
mkdir -p "$(dirname "$CONTAINERS_CONF")"
cat > "$CONTAINERS_CONF" <<EOF
[engine]
helper_binaries_dir = [
    "${PODMAN_ENV_DIR}/libexec/podman",
    "${PODMAN_ENV_DIR}/lib/podman"${CNI_HELPERS}
]

[network]
network_backend = "${NET_BACKEND}"
EOF
export CONTAINERS_CONF

# Ensure rootless policy and storage
POLICY_FILE="${HOME}/.config/containers/policy.json"
if [ ! -f "$POLICY_FILE" ]; then
    mkdir -p "$(dirname "$POLICY_FILE")"
    echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$POLICY_FILE"
fi
mkdir -p "${HOME}/.local/share/containers"

echo "Using podman: $PODMAN_BIN (network: $NET_BACKEND)"

# --- Image Loading ---
if [ -n "${image:-}" ] && [ -f "$image" ]; then
    # Skip loading if image is already in local storage
    if podman image exists "$DOCKER_IMAGE" 2>/dev/null; then
        echo "Image already loaded: $DOCKER_IMAGE"
    else
        echo "Loading pre-cached image from: $image"
        case "$image" in
            *.tar.zst|*.zst)
                zstd -d "$image" --stdout | podman load
                ;;
            *)
                podman load -i "$image"
                ;;
        esac
        LOADED_IMAGE=$(podman images --format '{{.Repository}}:{{.Tag}}' | grep -v "<none>" | head -1)
        echo "Loaded image: $LOADED_IMAGE"
        DOCKER_IMAGE="$LOADED_IMAGE"
    fi
elif [ -n "${image:-}" ]; then
    echo "WARNING: image path set but file not found: $image"
    echo "Falling back to Docker Hub pull..."
    podman pull "$DOCKER_IMAGE"
else
    echo "No pre-cached image. Pulling from Docker Hub..."
    podman pull "$DOCKER_IMAGE"
fi

echo "Starting rstudio on port $PORT ..."

# --- Snapshot on Stop ---
_snapshot_cleanup() {
    local exit_code=$?
    if [ "${snapshot:-false}" = "true" ] || [ "${snapshot:-false}" = "True" ]; then
        echo "Snapshot enabled. Saving container state as zstd..."
        SNAPSHOT_DIR="$HOME/rstudio-snapshots"
        mkdir -p "$SNAPSHOT_DIR"

        TIMESTAMP=$(date +%Y%m%d%H%M%S)
        SNAPSHOT_TAG="rstudio-snapshot:${TIMESTAMP}"
        SNAPSHOT_ZSTD="$SNAPSHOT_DIR/rstudio-${job_id:-unknown}-${TIMESTAMP}.tar.zst"

        # Commit the running container to a new image
        podman commit "$CONTAINER_NAME" "$SNAPSHOT_TAG" 2>/dev/null || true

        # Save the committed snapshot with zstd compression
        echo "Saving snapshot to: $SNAPSHOT_ZSTD"
        podman save "$SNAPSHOT_TAG" 2>/dev/null | zstd -T0 -o "$SNAPSHOT_ZSTD" 2>/dev/null || true

        # Upload to S3 if outdir is set
        if [ -n "${outdir:-}" ]; then
            S3_UPLOAD_PATH="${outdir}/${job_id:-unknown}/"
            echo "Uploading snapshot to: $S3_UPLOAD_PATH"
            if command -v aws &>/dev/null; then
                aws s3 cp "$SNAPSHOT_ZSTD" "$S3_UPLOAD_PATH" \
                    --endpoint-url "${AWS_ENDPOINT_URL:-}" 2>/dev/null || true
            fi
        fi

        rm -f "$SNAPSHOT_ZSTD"
        echo "Snapshot complete."
    fi
    return $exit_code
}
trap _snapshot_cleanup EXIT

# --- Run RStudio Server ---
CONTAINER_R_LIBS="/home/rstudio/R/library"
CONTAINER_PY_SITE="/home/rstudio/.local/lib/python3.12/site-packages"

# Remove any existing container with the same name before starting.
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

podman run --rm -i \
    --name "$CONTAINER_NAME" \
    -p "$PORT:$PORT" \
    -v "$RSTUDIO_WORKSPACE:/home/rstudio" \
    "$DOCKER_IMAGE" \
    bash -c "mkdir -p $CONTAINER_R_LIBS $CONTAINER_PY_SITE && \
        exec rserver \
            --www-address=0.0.0.0 \
            --www-port=$PORT \
            --server-working-dir /home/rstudio \
            --auth-none=1 \
            --server-daemonize=0"
