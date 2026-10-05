# tests/lib/results.sh -- part of tests/lib.sh, which sources it; never run it on its own.
# Reading a scenario's result (field, fields) and checking the database over OQL (oql,
# oql_count, oql_value, await_row).

# --- 8. Reading the result ---
# field <json> <key> -- booleans and null as JSON spells them; plain strings unquoted.
field() {
  local json="$1" key="$2"
  # An empty result read as "" and failed the check below it with a wrong reason ("customer did
  # not see their invoice") while the page was right: the scenario's output had gone to /dev/null.
  [ -n "$json" ] || fail "field $key: no scenario result to read -- capture it: result=\$(scenario '...') (a scenario sent to /dev/null, or never run, leaves \$result empty)"
  printf '%s' "$json" | "$NODE" "$MDL_SHELL_HELPERS" field "$key"
}

# fields <json> <key...> -- one line per key, as field(), in one Node start:
#   { read -r opened; read -r count; } <<< "$(fields "$result" opened count)"
fields() {
  local json="$1"; shift
  printf '%s' "$json" | "$NODE" "$MDL_SHELL_HELPERS" fields "$@"
}

# --- 9. Data assertions (~0.03s each) ---
# oql "<query>" -- rows as JSON, or fail with mxcli's own error. An entity after FROM or JOIN
# is written Module."Entity"; one written without its module gets $MODULE.
oql() {
  local query output
  query="$(oql_qualified "$1")"
  # `if !` keeps the output and stops set -e exiting before the error is reported.
  if ! output="$("$MXCLI" oql -p "$APP_DIR/$MPR" --host "${ADMIN_HOST:-localhost}" \
                 --port "${ADMIN_PORT:-8090}" --json "$query" 2>&1)"; then
    fail "OQL failed: $(printf '%s' "$output" | grep -v '^$' | grep -v 'vibe-coded PoC' | head -2 | tr '\n' ' ')
   (write an entity as Module.\"Entity\", e.g. ${MODULE:-MyModule}.\"Order\"; reach an association with
   JOIN o/Module.Assoc/Module.Entity AS x; or count with oql_count <Entity> \"<where>\")"
  fi
  # mxcli appends a "(n rows)" line, so decode only the first JSON value.
  local json
  json="$(printf '%s' "$output" | "$NODE" "$MDL_SHELL_HELPERS" oql-decode)" || fail "OQL returned nothing to parse: $(printf '%s' "$output" | grep -v '^$' | head -2 | tr '\n' ' ')"
  printf '%s' "$json"
}

# The query with each entity after FROM or JOIN written Module."Entity": `"Order"` and `Order`
# take $MODULE, `"Sales.Order"` and `Sales.Order` become Sales."Order". A session spent five
# queries on "'Order' is not a valid entity path". Association paths (o/...) and subqueries pass.
oql_qualified() {   # oql_qualified <query>
  MODULE="${MODULE:-}" "$NODE" "$MDL_SHELL_HELPERS" oql-qualified "$1"
}

# The entity as OQL reads it: quoted, so one named Order (or another reserved word) parses.
oql_entity() {   # oql_entity <Entity>
  printf '%s."%s"' "$MODULE" "${1//\"/}"
}

# oql_count <Entity> ["<where>"] -- WHERE is OQL: reach associations with JOIN, not paths.
oql_count() {
  local entity="$1" where="${2:-}"
  [ -n "${MODULE:-}" ] || fail "oql_count needs a module: set MODULE=<YourModule> or run through tests/gate.sh"
  # One line: the runner shows only a test's last stderr line.
  case "$where" in
    \[*) fail "oql_count takes an OQL WHERE, not XPath: $where -- drop the brackets (Status = 'Paid'); across an association use oql \"SELECT COUNT(*) AS Total FROM ... AS i JOIN i/Module.Assoc/Module.Entity AS c WHERE c.Attr = 'x'\"" ;;
  esac
  local query="SELECT COUNT(*) AS Total FROM $(oql_entity "$entity")"
  # Not `[ -n "$where" ] && ...`: with set -e, the false test ends the function.
  if [ -n "$where" ]; then
    query="$query WHERE $where"
  fi
  # Captured, not piped: a failing oql must stop here, not feed the parser empty input.
  local json
  json="$(oql "$query")" || exit 1
  printf '%s' "$json" | "$NODE" "$MDL_SHELL_HELPERS" oql-count
}

# await_row <Entity> "<where>" [seconds] -- 0 once a row matches, 1 after <seconds> (default 8)
# or when the query itself fails.
await_row() {
  local entity="$1" where="$2" limit="${3:-8}" waited=0 count
  while :; do
    count="$(oql_count "$entity" "$where")" || return 1
    [ "$count" = "0" ] || return 0
    waited=$((waited + 1))
    [ "$waited" -ge "$((limit * 4))" ] && return 1
    perl -e 'select undef, undef, undef, 0.25'
  done
  return 0
}

# oql_value <Entity> <Attr> "<where>" -- 'no-such-row' if none; 'empty' for null or "";
# booleans print true/false, numbers as they are (0 stays 0).
oql_value() {
  local entity="$1" attribute="$2" where="$3"
  local json
  [ -n "${MODULE:-}" ] || fail "oql_value needs a module: set MODULE=<YourModule> or run through tests/gate.sh"
  json="$(oql "SELECT $attribute FROM $(oql_entity "$entity") WHERE $where")" || exit 1
  printf '%s' "$json" | "$NODE" "$MDL_SHELL_HELPERS" oql-value "$attribute"
}
