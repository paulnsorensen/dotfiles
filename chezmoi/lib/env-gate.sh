#!/bin/sh
# Filter positive env gates from a registry map before rendering runtime data.
# A gate passes only when its exported variable has the exact value "true".
# shellcheck disable=SC2034,SC2016  # sourced jq program
env_gate_jq='def gate_filter: with_entries(select((.value.gate // "") as $g | $g == "" or env[$g] == "true") | .value |= del(.gate));'
