#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

CLIENT_ROOT="LeanCli/Lib/Client.lean"
APP_ROOT="LeanCli/App/Main.lean"

if grep -REn '^import LeanCli\.(Wallet|Crypto|Keystore|Privacy|Daemon)' "$APP_ROOT" "$CLIENT_ROOT" LeanCli/Cli; then
  printf 'CLI isolation failed: forbidden runtime import in app/client roots or LeanCli/Cli\n' >&2
  exit 1
fi

if grep -REn '^import LeanCli$' "$APP_ROOT" "$CLIENT_ROOT" LeanCli/Cli; then
  printf 'CLI isolation failed: CLI imports root LeanCli module\n' >&2
  exit 1
fi

if ! grep -q '^import LeanCli.Lib.Client$' "$APP_ROOT"; then
  printf 'CLI isolation failed: app root must import LeanCli.Lib.Client\n' >&2
  exit 1
fi

if grep -E '^import ' "$APP_ROOT" | grep -Ev '^import LeanCli\.Lib\.Client$' | grep -q .; then
  printf 'CLI isolation failed: app root must not import anything except LeanCli.Lib.Client\n' >&2
  exit 1
fi

seen=""
check_no_transitive_keystore() {
  local module="$1"
  case " $seen " in
    *" $module "*) return 0 ;;
  esac
  seen="$seen $module"

  local path="${module//.//}.lean"
  if [[ ! -f "$path" ]]; then
    return 0
  fi

  while IFS= read -r imported; do
    if [[ "$imported" == LeanCli.Keystore* || "$imported" == LeanCli.Daemon* ]]; then
      printf 'CLI isolation failed: %s transitively imports %s\n' "$module" "$imported" >&2
      exit 1
    fi
    check_no_transitive_keystore "$imported"
  done < <(sed -n 's/^import[[:space:]]\+\([^[:space:]]\+\)$/\1/p' "$path")
}

check_no_transitive_keystore LeanCli.App.Main

printf 'CLI isolation checks passed\n'
