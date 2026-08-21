#!/bin/bash
USER=$(whoami)
TMPDIR=${TMPDIR:-$RIVER_HOME/tmp}
CONTAINER="rstudio-4.4.2.sif"

# Absolute path to this tool directory (analysis/omicslab)
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$TOOL_DIR"
# Set-up temporary paths under $HOME so they exist both on the host and, via
# the $HOME:/home/rstudio bind, inside the container.
RSTUDIO_WORKSPACE="$HOME/rstudio-workspace"
mkdir -p $RSTUDIO_WORKSPACE/{run,var-lib-rstudio-server,local-share-rstudio}

eval "$(pixi shell-hook)"

R_BIN=$(which R)
PY_BIN=$(which python)

if [ ! -f "$TOOL_DIR/$CONTAINER" ]; then
        singularity pull "$TOOL_DIR/$CONTAINER" docker://docker.io/rocker/rstudio:4.4.2
fi

echo "Using R binary: $R_BIN"
echo "Using Python binary: $PY_BIN"
echo "Starting rstudio service on port $PORT ..."

RSTUDIO_HOME=$RSTUDIO_WORKSPACE/packages/rstudio
RSTUDIO_CONFIG=$RSTUDIO_WORKSPACE/config
mkdir -p $RSTUDIO_CONFIG

# rserver runs INSIDE the container, where the host path /home/river/... does
# not exist. $HOME is mounted at /home/rstudio, so translate every $HOME-relative
# path (R/Python binaries, working dir) to the in-container mount point.
CONTAINER_HOME="/home/rstudio"
cpath() { case "$1" in "$HOME"*) echo "${CONTAINER_HOME}${1#$HOME}";; *) echo "$1";; esac; }
CONTAINER_R_BIN=$(cpath "$R_BIN")
CONTAINER_PY_BIN=$(cpath "$PY_BIN")
CONTAINER_LD=$(cpath "${CONDA_PREFIX}/lib")

# RStudio Server runs fine as a non-root user. We only add --server-daemonize=0
# so rserver stays in the FOREGROUND instead of forking to the background; that
# keeps the studio job "running" for its whole lifetime. `script` provides the
# PTY rserver expects.
#
# The container working directory (--pwd) and --server-working-dir must reference
# a path that exists INSIDE the container (/home/rstudio), not the host path.
exec script -q -c "singularity run --pwd /home/rstudio \
        --bind $RSTUDIO_WORKSPACE/run:/run \
        --bind $RSTUDIO_WORKSPACE/var-lib-rstudio-server:/var/lib/rstudio-server \
        --bind /sys/fs/cgroup/:/sys/fs/cgroup/:ro \
        --bind $TOOL_DIR/database.conf:/etc/rstudio/database.conf \
        --bind $TOOL_DIR/rsession.conf:/etc/rstudio/rsession.conf \
        --bind $RSTUDIO_WORKSPACE/local-share-rstudio:/home/rstudio/.local/share/rstudio \
        --bind $HOME:/home/rstudio \
        --env RSTUDIO_WHICH_R=$CONTAINER_R_BIN \
        --env RETICULATE_PYTHON=$CONTAINER_PY_BIN \
        $TOOL_DIR/$CONTAINER \
        rserver \
                --www-address=0.0.0.0 \
                --www-port=${PORT:-6868} \
                --server-working-dir /home/rstudio \
                --rsession-which-r=$CONTAINER_R_BIN \
                --rsession-ld-library-path=$CONTAINER_LD \
                --auth-none=1 \
                --server-user $USER \
                --server-daemonize=0"
