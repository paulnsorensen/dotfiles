#!/usr/bin/env bash
# Public package command and Markdown presentation for local reports.
sessions_package() {
    uvx agent-session-analytics==0.2.0 "$@"
}

sessions_package_sql_markdown() {
    local rows description=""
    rows="$(sessions_package sql -- "$1")" || return $?
    if [[ "${rows//[[:space:]]/}" == "[]" ]]; then
        description="$(sessions_package sql -- "DESCRIBE $1")" || return $?
    fi
    printf '%s\n' "$rows" | python3 -c '
import json
import sys

rows = json.load(sys.stdin)
if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
    raise SystemExit("Package SQL did not return row dictionaries")
if rows:
    columns = list(rows[0])
else:
    description = json.loads(sys.argv[1])
    if not isinstance(description, list) or any(
        not isinstance(column, dict) or not isinstance(column.get("column_name"), str)
        for column in description
    ):
        raise SystemExit("Package SQL did not return column metadata")
    columns = [column["column_name"] for column in description]
def cell(value):
    if value is None:
        return "NULL"
    if isinstance(value, (dict, list)):
        value = json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return str(value).lower()
    return str(value).replace("|", r"\|").replace("\r\n", "<br>").replace("\n", "<br>").replace("\r", "<br>")

print("| " + " | ".join(cell(column) for column in columns) + " |")
print("| " + " | ".join("---" for _ in columns) + " |")
for row in rows:
    print("| " + " | ".join(cell(row.get(column)) for column in columns) + " |")
' "$description"
}
