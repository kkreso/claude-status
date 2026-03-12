#!/bin/bash
# Shared JSON utilities for Claude Status plugin scripts.
# No external dependencies — uses only bash builtins and sed.

# Escape a string for safe interpolation into JSON string values.
# Handles backslash, double quote, and control characters.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

# Extract a string value from JSON using only sed (no jq dependency).
# Returns empty string (not failure) when key is absent.
extract_json_string() {
    local key="$1"
    local json="$2"
    local result
    result=$(echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p") || true
    echo "${result%%
*}"
}
