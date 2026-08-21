#!/bin/bash
set -euo pipefail

USER=$(whoami)
DOCKER_IMAGE="docker.io/rocker/rstudio:4.4.2"
CONTAINER_NAME="rstudio-server"

# Absolute path to this tool directory (analysis/omicslab)
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TOOL_DIR"

# Set-up temporary paths under $HOME so they exist both on the host and, via
# the $HOME:/home/rstudio bind, inside the container.
RSTUDIO_WORKSPACE="$HOME/rstudio-workspace"
mkdir -p $RSTUDIO_WORKSPACE/{run,var-lib-rstudio-server,local-share-rstudio}

eval "$(pixi shell-hook)"

# Ensure podman can run rootless: policy.json + storage dir
POLICY_FILE="${HOME}/.config/containers/policy.json"
if [ ! -f "$POLICY_FILE" ]; then
    mkdir -p "$(dirname "$POLICY_FILE")"
    echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$POLICY_FILE"
fi
STORAGE_DIR="${HOME}/.local/share/containers"
mkdir -p "$STORAGE_DIR"

R_BIN=$(which R)
PY_BIN=$(which python)
ENV_DIR="$(cd "$(dirname "$(dirname "$R_BIN")")" && pwd)"

echo "Using R binary: $R_BIN"
echo "Using Python binary: $PY_BIN"

# Writable paths inside the container for user-installed packages.
# The pixi env (/opt/toolenv) is bind-mounted read-only — packages installed
# there would be lost on container restart. Instead, point R and Python to
# writable paths inside the container's writable layer so they are captured
# by `podman commit` (snapshot).
CONTAINER_R_LIBS="/home/rstudio/R/library"
CONTAINER_PY_SITE="/home/rstudio/.local/lib/python3.12/site-packages"
mkdir -p "$RSTUDIO_WORKSPACE/$CONTAINER_R_LIBS" "$RSTUDIO_WORKSPACE/$CONTAINER_PY_SITE"

# --- Image Loading ---
# If image param is set and points to a downloaded file, load it via podman.
# Supports raw tar, gzip (.tar.gz), and zstd (.tar.zst, .zst) compression.
# Otherwise pull from Docker Hub.
if [ -n "${image:-}" ] && [ -f "$image" ]; then
    echo "Loading pre-cached image from: $image"
    case "$image" in
        *.tar.zst|*.zst)
            zstd -d "$image" --stdout | podman load
            ;;
        *.tar.gz|*.tgz)
            pigz -d -c "$image" | podman load
            ;;
        *)
            podman load -i "$image"
            ;;
    esac
    LOADED_IMAGE=$(podman images --format '{{.Repository}}:{{.Tag}}' | grep -v "<none>" | head -1)
    echo "Loaded image: $LOADED_IMAGE"
    DOCKER_IMAGE="$LOADED_IMAGE"
elif [ -n "${image:-}" ]; then
    echo "WARNING: image path set but file not found: $image"
    echo "Falling back to Docker Hub pull..."
    podman pull "$DOCKER_IMAGE"
else
    echo "No pre-cached image. Pulling from Docker Hub..."
    podman pull "$DOCKER_IMAGE"
fi

echo "Starting rstudio service on port ${PORT:-6868} ..."

# --- Snapshot on Stop ---
# If snapshot=true, commit the container to a new image and save as compressed tar on exit.
_snapshot_cleanup() {
    local exit_code=$?
    if [ "${snapshot:-false}" = "true" ] || [ "${snapshot:-false}" = "True" ]; then
        echo "Snapshot enabled. Saving container state..."
        SNAPSHOT_DIR="$HOME/rstudio-snapshots"
        mkdir -p "$SNAPSHOT_DIR"

        TIMESTAMP=$(date +%Y%m%d%H%M%S)
        SNAPSHOT_TAR="$SNAPSHOT_DIR/rstudio-${job_id:-unknown}-${TIMESTAMP}.tar"
        SNAPSHOT_ZSTD="$SNAPSHOT_TAR.zst"

        # Commit the running container to a new image
        podman commit "$CONTAINER_NAME" "rstudio-snapshot:${TIMESTAMP}" 2>/dev/null || true

        # Save with zstd compression (faster + better compression than gzip)
        echo "Saving snapshot to: $SNAPSHOT_ZSTD"
        podman save "$DOCKER_IMAGE" 2>/dev/null | zstd -T0 -o "$SNAPSHOT_ZSTD" 2>/dev/null || \
            podman save -o "$SNAPSHOT_TAR" "$DOCKER_IMAGE" 2>/dev/null

        # Upload to S3 if outdir is set
        if [ -n "${outdir:-}" ]; then
            S3_UPLOAD_PATH="s3://${bucket_name:-genomics}/${outdir}/${job_id:-unknown}/"
            echo "Uploading snapshot to: $S3_UPLOAD_PATH"
            if command -v aws &>/dev/null; then
                aws s3 cp "$SNAPSHOT_ZSTD" "$S3_UPLOAD_PATH" \
                    --endpoint-url "${AWS_ENDPOINT_URL:-}" 2>/dev/null || \
                aws s3 cp "$SNAPSHOT_TAR" "$S3_UPLOAD_PATH" \
                    --endpoint-url "${AWS_ENDPOINT_URL:-}" 2>/dev/null || true
            fi
        fi

        # Clean up local snapshot after upload
        rm -f "$SNAPSHOT_TAR" "$SNAPSHOT_ZSTD"
        echo "Snapshot complete."
    fi
    return $exit_code
}
trap _snapshot_cleanup EXIT

# --- Run RStudio Server ---
# Podman run: --rm removes container on exit, -i keeps stdin open for signal handling.
# --server-daemonize=0 keeps rserver in foreground so the job stays "running".
# `script` provides the PTY rserver expects.
exec script -q -c "podman run --rm -i \
    --name $CONTAINER_NAME \
    -p ${PORT:-6868}:${PORT:-6868} \
    -v $RSTUDIO_WORKSPACE/run:/run \
    -v $RSTUDIO_WORKSPACE/var-lib-rstudio-server:/var/lib/rstudio-server \
    -v $TOOL_DIR/database.conf:/etc/rstudio/database.conf \
    -v $TOOL_DIR/rsession.conf:/etc/rstudio/rsession.conf \
    -v $RSTUDIO_WORKSPACE/local-share-rstudio:/home/rstudio/.local/share/rstudio \
    -v $HOME:/home/rstudio \
    -v $ENV_DIR:/opt/toolenv \
    -e RSTUDIO_WHICH_R=/opt/toolenv/bin/R \
    -e RETICULATE_PYTHON=/opt/toolenv/bin/python \
    -e R_LIBS_USER=$CONTAINER_R_LIBS \
    -e PYTHONPATH=$CONTAINER_PY_SITE \
    $DOCKER_IMAGE \
    bash -c \"mkdir -p $CONTAINER_R_LIBS $CONTAINER_PY_SITE && \
        exec rserver \
            --www-address=0.0.0.0 \
            --www-port=${PORT:-6868} \
            --server-working-dir /home/rstudio \
            --rsession-which-r=/opt/toolenv/bin/R \
            --rsession-ld-library-path=/opt/toolenv/lib \
            --auth-none=1 \
            --server-user $USER \
            --server-daemonize=0\""
