#!/usr/bin/env bash
# Print the usage text for the sync tool.

name=$(basename "$0")

echo "Usage: $name [options] SOURCE DEST"
echo ""
echo "Copy SOURCE to DEST and keep a backup of every replaced file."
echo ""
echo "Options:"
echo "  -n        dry run; print what would change"
echo "  -b DIR    put backups in DIR (default: \$HOME/.backups)"
echo '  -x GLOB   skip files that match GLOB, for example "*.tmp"'
echo '  -v        verbose; print the `rsync` command before it runs'
echo '  -j N      run N copies at once (default: $(nproc))'
echo ""
echo -e "Columns:\tNAME\tSIZE\tSTATUS"
echo ""
echo "Exit status is 0 on success and 2 when SOURCE is missing."
