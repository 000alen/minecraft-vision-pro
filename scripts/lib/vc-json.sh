#!/usr/bin/env bash

# JSON helpers used by shell tooling. Prefer python's parser; keep a tiny sed
# fallback for early doctor/preflight contexts.

json_field() {
  local json="$1" key="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    v=d.get(sys.argv[1],"")
    print("" if v is None else (str(v).lower() if isinstance(v,bool) else v))
except Exception:
    pass' "$key" 2>/dev/null && return 0
  fi
  printf '%s' "$json" | sed -n "s/.*\"$key\":\"\{0,1\}\([^,\"}]*\).*/\1/p" | head -1
}
