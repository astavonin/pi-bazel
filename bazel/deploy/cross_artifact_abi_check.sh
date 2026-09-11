#!/usr/bin/env bash
#
# Asserts the cross artifact is aarch64 and carries no C++ runtime, without a
# live device — so CI runners with no Pi attached still guard the invariant.
set -euo pipefail

# --- begin runfiles.bash initialization v3 ---
# Copy-pasted from the Bazel Bash runfiles library v3.
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo >&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

# readelf's canonical repo name is bzlmod-generated, so it arrives as an
# $(rlocationpath) argument rather than a hardcoded path.
if ! artifact="$(rlocation pi_bazel/src/hello/hello)" || [[ -z "${artifact}" ]]; then
  echo "HARNESS-FAILED: could not resolve //src/hello:hello via rlocation" >&2
  exit 1
fi
if ! readelf="$(rlocation "$1")" || [[ -z "${readelf}" ]]; then
  echo "HARNESS-FAILED: could not resolve @llvm_x64//:readelf via rlocation" >&2
  exit 1
fi

machine="$("${readelf}" -h "${artifact}" | awk -F': *' '/Machine:/ {print $2}')"
if [[ "${machine}" != "AArch64" ]]; then
  echo "FAIL: expected an AArch64 artifact, got '${machine}'" >&2
  exit 1
fi

needed="$("${readelf}" -d "${artifact}" | grep NEEDED || true)"
# Positive assertion first: empty output would satisfy the deny-list below
# without having inspected anything.
if ! printf '%s\n' "${needed}" | grep -q 'libc\.so\.6'; then
  echo "FAIL: expected libc.so.6 in NEEDED, got: ${needed}" >&2
  exit 1
fi
# Deny-list rather than allowlist: NEEDED also carries libm, libdl and the
# loader, which an exact list would reject.
if denylist_hit="$(printf '%s\n' "${needed}" | grep -E 'libstdc\+\+|libc\+\+|libgcc_s')"; then
  echo "FAIL: c++ runtime present in NEEDED: ${denylist_hit}" >&2
  exit 1
fi

echo "PASSED: aarch64 artifact carries no C++ runtime NEEDED entry"
