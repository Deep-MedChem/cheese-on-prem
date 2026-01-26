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
        export $line
        # You can process each line as needed here
        # For example, you could add further processing logic
    done < "$file"

}


export_env_vars ${HOME}/.config/cheese/cheese-env-file.conf
