#!/bin/bash

echo Installing CHEESE...

# Environment file is in ./config/cheese-env.conf.template
env_file="./config/cheese-env.conf.template"

# Define Env variables

echo "Preparing folders..."

mkdir -p "${HOME}/.config"
mkdir -p "${HOME}/.config/cheese"
chmod -R 777 "${HOME}/.config/cheese"

mkdir -p "${HOME}/.local"
mkdir -p "${HOME}/.local/bin"
mkdir -p "${HOME}/.local/bin/cheese"
chmod -R 777 "${HOME}/.local/bin/cheese"

# ── Job-data directory ────────────────────────────────────────────────────────
# CHEESE persists job state (search jobs, downloads) on disk. The jobs containers
# and the file-server mount this directory; if it's missing the file-server's
# `http.server --directory ...` exits and `restart: unless-stopped` turns that
# into a crash loop. Prompt for a location, defaulting to the standard XDG data
# path, then create it and persist the choice so every container agrees on it.
DEFAULT_JOBS_DATA_PATH="${HOME}/.local/share/cheese-jobs"
read -r -p "Directory for CHEESE job data [${DEFAULT_JOBS_DATA_PATH}]: " JOBS_DATA_PATH_INPUT
# ENTER (or non-interactive stdin) → roll with the default.
JOBS_DATA_PATH="${JOBS_DATA_PATH_INPUT:-$DEFAULT_JOBS_DATA_PATH}"
# Expand a leading ~ since `read` keeps it literal.
JOBS_DATA_PATH="${JOBS_DATA_PATH/#\~/$HOME}"
echo "Using job-data directory: ${JOBS_DATA_PATH}"
mkdir -p "${JOBS_DATA_PATH}"

bash ./install/configure-bashrc.sh


echo "Setting Environment configuration files..."


convert_to_absolute_path() {
    local input_path="$1"

    # Check if the path is already absolute
    if [[ "$input_path" == /* ]]; then
        # It's already absolute, just return it
        echo "$input_path"
    else
        # It's a relative path, convert it to absolute
        echo "$(pwd)/$input_path"
    fi
}

env_file=$(convert_to_absolute_path $env_file) 

set -e

ip_address=$(hostname)

# Copy testing conf files
cp "$PWD/config/cheese_test_config_file.yaml" "${HOME}/.config/cheese/cheese_config_file.yaml"
cp "$PWD/config/cheese_test_explorer_config_file.yaml" "${HOME}/.config/cheese/cheese-explorer-conf.yaml"
# Copy nginx and Oauth2 config files
cp "$PWD/config/nginx.conf.template" "${HOME}/.config/cheese/nginx.conf"
cp "$PWD/config/nginx.crt.template" "${HOME}/.config/cheese/nginx.crt"
cp "$PWD/config/nginx.key.template" "${HOME}/.config/cheese/nginx.key"
cp "$PWD/config/oauth2.env.template" "${HOME}/.config/cheese/oauth2.env"

# Setting license file
echo "" > "${HOME}/.config/cheese/cheese_license_file.json"
# Set from provided env_file
if [ ! "$env_file" = "" ]; then
    # An existing environment config may hold edits made via `cheese update-env`.
    # Preserve it by default; only regenerate from the template if the user
    # explicitly opts in.
    overwrite_env="n"
    if [ -f "${HOME}/.config/cheese/cheese-env-file.conf" ]; then
        echo "Existing environment config found at ${HOME}/.config/cheese/cheese-env-file.conf"
        read -p "Overwrite it with a fresh config from the template (y/N)? " overwrite_env
    fi

    if [ -f "${HOME}/.config/cheese/cheese-env-file.conf" ] && [[ ! "$overwrite_env" =~ ^[Yy]$ ]]; then
        echo "Preserving existing environment config. (Run 'cheese update-env' to edit it.)"
    else
        echo Setting from file $env_file
        cat $env_file > "${HOME}/.config/cheese/cheese-env-file.conf";
        echo "" >> "${HOME}/.config/cheese/cheese-env-file.conf";
        echo "REPO_FOLDER=$PWD" >> "${HOME}/.config/cheese/cheese-env-file.conf";
        echo "IP=$ip_address" >> "${HOME}/.config/cheese/cheese-env-file.conf";
        echo "CONFIG_FILE=${HOME}/.config/cheese/cheese_config_file.yaml" >> "${HOME}/.config/cheese/cheese-env-file.conf";
        echo "CHEESE_LICENSE_FILE=${HOME}/.config/cheese/cheese_license_file.json" >> "${HOME}/.config/cheese/cheese-env-file.conf";
        echo "JOBS_DATA_PATH=${JOBS_DATA_PATH}" >> "${HOME}/.config/cheese/cheese-env-file.conf";
        echo "TESTING=false" >> "${HOME}/.config/cheese/cheese-env-file.conf";
        echo "VISUALIZATION=false" >> "${HOME}/.config/cheese/cheese-env-file.conf";
        sed -i '/^$/d' "${HOME}/.config/cheese/cheese-env-file.conf"
    fi

    echo "OUTPUT_DIRECTORIES:" >> "${HOME}/.config/cheese/cheese_config_file.yaml";
    echo "  TEST: '$PWD/tests/test_db'" >> "${HOME}/.config/cheese/cheese_config_file.yaml";

    # Initializing license file

else
    exit "Please specify an environment configuration file. To do that, please modify the template in config/cheese-env.conf.template"    

fi



# Define a function to export environment variables from a file
export_env_vars() {
    local file="$1"

    # Check if the file exists and is readable
    if [ ! -f "$file" ]; then
        echo "Error: File '$file' not found or is not a regular file."
    fi

    # Read each line from the file
    while IFS= read -r line; do
        # Skip blank lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        export "$line"
    done < "$file"

}


export_env_vars "${HOME}/.config/cheese/cheese-env-file.conf"

cd "${REPO_FOLDER}/scripts"
# INSTALL_MODE makes update-scripts preserve already-installed scripts unless
# the user opts in to overwrite. Standalone `cheese update-scripts` leaves this
# unset and always refreshes.
INSTALL_MODE=1 bash update-scripts
