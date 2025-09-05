#!/bin/bash

# Define the block to search for
read -r -d '' block << 'EOF'
if [ -d "$HOME/.local/bin/cheese" ]; then
    PATH="$HOME/.local/bin/cheese:$PATH"
fi
EOF

# Use a temp file to store the block
tmpfile=$(mktemp)
echo "$block" > "$tmpfile"

# Check if the block exists in ~/.bashrc
if grep -Ff "$tmpfile" "$HOME/.bashrc" | grep -q 'PATH="\$HOME/.local/bin/cheese:\$PATH"'; then
    # echo "Block already exists in .bashrc"
    echo
else
    echo -e "\n# Add local bin to PATH\n$block" >> "$HOME/.bashrc"
    # echo "Block added to .bashrc"
fi

# Cleanup
rm "$tmpfile"

source $HOME/.bashrc