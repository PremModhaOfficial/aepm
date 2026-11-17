#!/usr/bin/env bash
# Prove `run.sh` takes its documented BuildKit retry, and only when it should.
#
# No container runtime runs here: a stub runtime fails the first `build` with
# the message the host really prints, so the assertion covers `run.sh`'s own
# branch without Docker, a network or a 10-minute Arch image.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# SIM_STUB_FAILS_ONCE: the first build dies with the BuildKit sandbox fault, the
# retry succeeds. Any other value: the first build dies with a Dockerfile error,
# which must not be retried.
cat >"$tmp/runtime" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == build && ! -f $SIM_STUB_STATE ]]; then
    : >"$SIM_STUB_STATE"
    case $SIM_STUB_MODE in
    veth)
        echo 'failed to set up container networking: failed to create endpoint' \
            'x on network bridge: failed to add the host (veth1a2b) <=>' \
            'sandbox (veth3c4d) pair interfaces: operation not supported' >&2
        ;;
    dockerfile)
        echo 'ERROR: failed to solve: process "/bin/sh -c false" did not complete' \
            'successfully: exit code: 1' >&2
        ;;
    esac
    exit 1
fi
printf 'build DOCKER_BUILDKIT=%s %s\n' "${DOCKER_BUILDKIT-}" "$*"
STUB
chmod +x "$tmp/runtime"

# build <mode> — run the build path against the stub, print output, return rc.
build() {
    export SIM_STUB_MODE=$1
    export SIM_STUB_STATE=$tmp/failed-once
    export SIM_LOG_DIR=$tmp/logs-$1
    rm -f "$SIM_STUB_STATE"
    ( cd "$repo" && SIM_RUNTIME=$tmp/runtime SIM_IMAGE=aepm-sim:retry \
        ./sim/run.sh --build-only </dev/null 2>&1 )
}

# A host the retry exists for: it fires, and the second build is the classic
# builder on the host network.
out=$(build veth) && rc=0 || rc=$?
[[ $rc == 0 ]] ||
    { printf 'sim: retry: run.sh exited %s where the retry must succeed:\n%s\n' "$rc" "$out" >&2; exit 1; }
grep -q 'retrying once with DOCKER_BUILDKIT=0 --network host' <<<"$out" ||
    { printf 'sim: retry: run.sh did not take the retry:\n%s\n' "$out" >&2; exit 1; }
grep -q 'DOCKER_BUILDKIT=0 build .*--network host' <<<"$out" ||
    { printf 'sim: retry: the retry did not switch the builder:\n%s\n' "$out" >&2; exit 1; }

# A real Dockerfile error is a real error: it fails loudly and is not retried.
out=$(build dockerfile) && rc=0 || rc=$?
[[ $rc != 0 ]] ||
    { printf 'sim: retry: a Dockerfile error exited 0:\n%s\n' "$out" >&2; exit 1; }
grep -q 'not retrying' <<<"$out" ||
    { printf 'sim: retry: a Dockerfile error was retried:\n%s\n' "$out" >&2; exit 1; }

echo "sim: build retry: fires on the BuildKit sandbox fault, refuses a Dockerfile error"
