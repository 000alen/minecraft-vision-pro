#!/usr/bin/env bash

# Shared terminal output helpers.

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YEL=""; C_BLUE=""; C_BOLD=""
fi

step() { printf '%s\n' "${C_BOLD}${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ok()   { printf '%s\n' "  ${C_GREEN}✓${C_RESET} $*"; }
warn() { printf '%s\n' "  ${C_YEL}!${C_RESET} $*"; }
bad()  { printf '%s\n' "  ${C_RED}✗${C_RESET} $*"; }
info() { printf '%s\n' "  ${C_DIM}·${C_RESET} $*"; }
die()  { printf '%s\n' "${C_RED}error:${C_RESET} $*" >&2; exit 1; }
