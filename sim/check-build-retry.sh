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
# SIM_STUB_IMAGE_PRESENT: what `image inspect` answers. Unset or 0 is the
# "never built" case, which must stop run.sh rather than start a container.
if [[ $1 == image && $2 == inspect ]]; then
    if [[ ${SIM_STUB_IMAGE_PRESENT:-0} == 1 ]]; then
        echo '[]'
        exit 0
    fi
    echo "Error response from daemon: No such image: ${!#}" >&2
    exit 1
fi
if [[ $1 == run ]]; then
    printf 'run %s\n' "$*"
    exit 0
fi
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

# SIM_NO_BUILD: CI builds the image with a layer cache outside run.sh and hands
# it over. Two claims: the image is used without a build, and a missing image
# stops the run instead of letting every scenario pass against nothing.
scenario=sim/scenarios/03-binary-readonly-safety.sh
nobuild() {
    ( cd "$repo" && SIM_RUNTIME=$tmp/runtime SIM_IMAGE=aepm-sim:ci SIM_NO_BUILD=1 \
        SIM_STUB_IMAGE_PRESENT=$1 SIM_LOG_DIR=$tmp/logs-nobuild-$1 \
        ./sim/run.sh "$scenario" </dev/null 2>&1 )
}

out=$(nobuild 0) && rc=0 || rc=$?
[[ $rc != 0 ]] ||
    { printf 'sim: no-build: a missing image exited 0:\n%s\n' "$out" >&2; exit 1; }
grep -q 'refusing to run against nothing' <<<"$out" ||
    { printf 'sim: no-build: run.sh did not refuse a missing image:\n%s\n' "$out" >&2; exit 1; }

out=$(nobuild 1) && rc=0 || rc=$?
[[ $rc == 0 ]] ||
    { printf 'sim: no-build: run.sh exited %s with the image present:\n%s\n' "$rc" "$out" >&2; exit 1; }
grep -q 'build: skipped' <<<"$out" ||
    { printf 'sim: no-build: run.sh did not report the skipped build:\n%s\n' "$out" >&2; exit 1; }
grep -q 'build DOCKER_BUILDKIT' <<<"$out" &&
    { printf 'sim: no-build: run.sh built the image anyway:\n%s\n' "$out" >&2; exit 1; }
grep -q 'run --rm --name sim-' <<<"$out" ||
    { printf 'sim: no-build: the scenario did not run against the image:\n%s\n' "$out" >&2; exit 1; }

out=$( cd "$repo" && SIM_RUNTIME=$tmp/runtime SIM_NO_BUILD=1 ./sim/run.sh --build-only </dev/null 2>&1 ) && rc=0 || rc=$?
[[ $rc != 0 ]] ||
    { printf 'sim: no-build: --build-only and SIM_NO_BUILD=1 both accepted:\n%s\n' "$out" >&2; exit 1; }

echo "sim: build retry: fires on the BuildKit sandbox fault, refuses a Dockerfile error"
echo "sim: no-build: uses a handed-over image, refuses a missing one, refuses --build-only"
