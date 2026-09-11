#!/usr/bin/env bash
#
# Deploys //src/hello:hello to the Raspberry Pi, runs it, and asserts both the
# sentinel output and that no C++ runtime appears in the resolved libraries.
#
# Exit codes:
#   0 - PASSED
#   1 - SMOKE-FAILED         the device answered but the artifact was wrong
#   2 - DEVICE-UNREACHABLE   ssh/scp failed; the toolchain is not implicated
#   3 - HARNESS-FAILED       a build-graph or script fault; neither the
#                            device nor the artifact is implicated
# The label is the first line of output, because Bazel reports all failures
# identically.
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

readonly PI_SSH_HOST="${PI_SSH_HOST:-pi}"
readonly CONNECT_TIMEOUT_SECS=5

# Bounds the powered-off case, which would otherwise hang past the test timeout.
readonly SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout="${CONNECT_TIMEOUT_SECS}"
  -o StrictHostKeyChecking=accept-new
)

fail_unreachable() {
  echo "DEVICE-UNREACHABLE: $1"
  exit 2
}

fail_smoke() {
  echo "SMOKE-FAILED: $1"
  exit 1
}

fail_harness() {
  echo "HARNESS-FAILED: $1"
  exit 3
}

# Under -e a failing substitution aborts the assignment, so `||` is what makes
# the failure observable at all.
if ! artifact="$(rlocation pi_bazel/src/hello/hello)" || [[ -z "${artifact}" ]]; then
  fail_harness "could not resolve //src/hello:hello via rlocation"
fi

if ! sentinel_file="$(rlocation pi_bazel/src/hello/sentinel.txt)" || [[ -z "${sentinel_file}" ]]; then
  fail_harness "could not resolve //src/hello:sentinel.txt via rlocation"
fi
# Same file the binary's header is generated from, so the two cannot drift.
sentinel_text="$(cat "${sentinel_file}")"
readonly SENTINEL="${sentinel_text}"

# Unique per invocation so concurrent runs cannot share a remote path.
remote_path="/tmp/pi-bazel-smoke.$$.$(date +%s%N)"
copied=0

cleanup() {
  # Both guards matter: either alone would delete a file this run does not own.
  if [[ -n "${remote_path:-}" && "${copied}" -eq 1 ]]; then
    # shellcheck disable=SC2029  # remote_path must expand client-side
    ssh "${SSH_OPTS[@]}" -- "${PI_SSH_HOST}" "rm -f -- '${remote_path}'" >/dev/null 2>&1 || true
  fi
}
# INT/TERM too: Bazel's timeout sends SIGTERM, which skips EXIT traps.
trap cleanup EXIT INT TERM

if ! ssh "${SSH_OPTS[@]}" -- "${PI_SSH_HOST}" true; then
  fail_unreachable "ssh to '${PI_SSH_HOST}' failed"
fi

if ! scp "${SSH_OPTS[@]}" -- \
    "${artifact}" "${PI_SSH_HOST}:${remote_path}" >/dev/null; then
  fail_unreachable "scp to '${PI_SSH_HOST}:${remote_path}' failed"
fi
copied=1

# shellcheck disable=SC2029  # remote_path must expand client-side
if ! ldd_output="$(ssh "${SSH_OPTS[@]}" -- "${PI_SSH_HOST}" "ldd -- '${remote_path}'")"; then
  fail_smoke "ldd failed to run on the device"
fi
# Empty output must fail: a check that cannot observe anything would pass.
if [[ -z "${ldd_output}" ]]; then
  fail_smoke "library inspection returned no output"
fi
# Positive assertion first: output naming none of the denied sonames would
# otherwise pass without proving anything.
if ! printf '%s\n' "${ldd_output}" | grep -q 'libc\.so\.6'; then
  fail_smoke "expected libc.so.6 not present in library inspection: ${ldd_output}"
fi
# Deny-list, not allowlist: ldd also prints linux-vdso.so.1 on aarch64.
if denylist_hit="$(printf '%s\n' "${ldd_output}" | grep -E 'libstdc\+\+|libc\+\+|libgcc_s')"; then
  fail_smoke "c++ runtime present: ${denylist_hit}"
fi

# shellcheck disable=SC2029  # remote_path must expand client-side
if ! run_output="$(ssh "${SSH_OPTS[@]}" -- "${PI_SSH_HOST}" "'${remote_path}'")"; then
  fail_smoke "artifact exited non-zero on the device"
fi

if [[ "${run_output}" != *"${SENTINEL}"* ]]; then
  fail_smoke "sentinel absent from device output: ${run_output}"
fi

echo "PASSED: ${SENTINEL}"
