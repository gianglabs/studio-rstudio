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

# rserver runs INSIDE the container, where host paths like /home/river/... do
# not exist. $HOME is mounted at /home/rstudio, but the tool's pixi env may
# live outside $HOME's prefix, so instead we bind the pixi env at a FIXED
# in-container path (/opt/toolenv) and point rserver at that. This avoids any
# fragile host->container path translation.
ENV_DIR="$(cd "$(dirname "$(dirname "$R_BIN")")" && pwd)"

# RStudio Server runs fine as a non-root user. We only add --server-daemonize=0
# so rserver stays in the FOREGROUND instead of forking to the background; that
# keeps the studio job "running" for its whole lifetime. `script` provides the
# PTY rserver expects.
#
# The container working directory (--pwd) and --server-working-dir reference
# /home/rstudio, which is the in-container mount of $HOME.
exec script -q -c "singularity run --pwd /home/rstudio \
        --bind $RSTUDIO_WORKSPACE/run:/run \
        --bind $RSTUDIO_WORKSPACE/var-lib-rstudio-server:/var/lib/rstudio-server \
        --bind /sys/fs/cgroup/:/sys/fs/cgroup/:ro \
        --bind $TOOL_DIR/database.conf:/etc/rstudio/database.conf \
        --bind $TOOL_DIR/rsession.conf:/etc/rstudio/rsession.conf \
        --bind $RSTUDIO_WORKSPACE/local-share-rstudio:/home/rstudio/.local/share/rstudio \
        --bind $HOME:/home/rstudio \
        --bind $ENV_DIR:/opt/toolenv \
        --env RSTUDIO_WHICH_R=/opt/toolenv/bin/R \
        --env RETICULATE_PYTHON=/opt/toolenv/bin/python \
        $TOOL_DIR/$CONTAINER \
        rserver \
                --www-address=0.0.0.0 \
                --www-port=${PORT:-6868} \
                --server-working-dir /home/rstudio \
                --rsession-which-r=/opt/toolenv/bin/R \
                --rsession-ld-library-path=/opt/toolenv/lib \
                --auth-none=1 \
                --server-user $USER \
                --server-daemonize=0"
