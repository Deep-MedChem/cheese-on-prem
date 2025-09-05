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

# Setting license file
echo "" > "${HOME}/.config/cheese/cheese_license_file.json"
# Set from provided env_file
if [ ! "$env_file" = "" ]; then
    echo Setting from file $env_file
    cat $env_file > "${HOME}/.config/cheese/cheese-env-file.conf";
    echo "" >> "${HOME}/.config/cheese/cheese-env-file.conf";
    echo "REPO_FOLDER=$PWD" >> "${HOME}/.config/cheese/cheese-env-file.conf";
    echo "IP=$ip_address" >> "${HOME}/.config/cheese/cheese-env-file.conf";
    echo "CONFIG_FILE=${HOME}/.config/cheese/cheese_config_file.yaml" >> "${HOME}/.config/cheese/cheese-env-file.conf";
    echo "CHEESE_LICENSE_FILE=${HOME}/.config/cheese/cheese_license_file.json" >> "${HOME}/.config/cheese/cheese-env-file.conf";
    echo "CHEESE_PACKAGE=cheese-ui,cheese-new-ui,cheese-database,cheese-api,cheese_inference,cheese-explorer" >> "${HOME}/.config/cheese/cheese-env-file.conf";
    echo "TESTING=false" >> "${HOME}/.config/cheese/cheese-env-file.conf";
    echo "VISUALIZATION=false" >> "${HOME}/.config/cheese/cheese-env-file.conf";
    sed -i '/^$/d' "${HOME}/.config/cheese/cheese-env-file.conf"

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
        export $line
        # You can process each line as needed here
        # For example, you could add further processing logic
    done < "$file"

}


export_env_vars "${HOME}/.config/cheese/cheese-env-file.conf"

cd "${REPO_FOLDER}/scripts"
bash update-scripts

update-images
