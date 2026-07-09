#!/bin/bash
# config_file=$1


# Define a function to export environment variables from a file
export_env_vars() {
    local file="$1"

    # Check if the file exists and is readable
    if [ ! -f "$file" ]; then
        echo "Error: File '$file' not found or is not a regular file."
    fi

    # Read each line from the file
    while IFS= read -r line; do
        # Skip blank lines and comments — otherwise a blank line runs `export`
        # with no args (dumping the whole environment) and unquoted values get
        # word-split/glob-expanded.
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        export "$line"
    done < "$file"

}


export_env_vars ${HOME}/.config/cheese/cheese-env-file.conf

# ── Container registry (ACR → ECR migration, 2026-07) ────────────────────────
# Central resolution, exported for every `cheese` subcommand and for
# docker-compose interpolation. AWS ECR is the only registry — the legacy Azure
# ACR (cheese.azurecr.io) account is retired. An explicit CHEESE_REGISTRY in
# the conf still overrides (e.g. a future mirror). (update-images and
# _compose-env repeat this default so they also work when invoked standalone,
# outside the dispatcher.)
export CHEESE_REGISTRY="${CHEESE_REGISTRY:-815935788477.dkr.ecr.us-east-1.amazonaws.com}"
