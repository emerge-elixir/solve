#!/usr/bin/env bash

set -euo pipefail

mode="${1:-all}"

run_quality() {
  MIX_ENV=test mix quality.fast
}

run_tests() {
  MIX_ENV=test mix test
}

run_dialyzer() {
  local output_file
  output_file="$(mktemp)"

  if MIX_ENV=dev mix dialyzer >"${output_file}" 2>&1; then
    cat "${output_file}"
    rm -f "${output_file}"
    return 0
  fi

  cat "${output_file}"

  if grep -q "File not found:" "${output_file}"; then
    echo "Detected a stale Dialyzer PLT; rebuilding local PLTs and retrying..." >&2
    rm -f _build/dev/dialyxir_*.plt _build/dev/dialyxir_*.plt.hash
    rm -f "${output_file}"
    MIX_ENV=dev mix dialyzer
    return 0
  fi

  rm -f "${output_file}"
  return 1
}

case "$mode" in
  quality)
    run_quality
    ;;
  test)
    run_tests
    ;;
  dialyzer)
    run_dialyzer
    ;;
  all)
    run_quality
    run_tests
    run_dialyzer
    ;;
  *)
    echo "usage: ./ci-tests.sh [quality|test|dialyzer|all]" >&2
    exit 1
    ;;
esac
