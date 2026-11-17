#!/usr/bin/env bash
# Drive the Arch simulation harness.
#
#   ./sim/run.sh                          build image, run every scenario
#   ./sim/run.sh --build-only             build image only
#   ./sim/run.sh --no-cache               rebuild from scratch, no layer cache
#   ./sim/run.sh sim/scenarios/03-*.sh    run selected scenarios
#   SIM_IMAGE=name:tag ./sim/run.sh       override the image tag
#   SIM_BINARY=target/release/aepm ./sim/run.sh
#                                         reuse a host-built binary (same Arch glibc)
#   SIM_LOG_DIR=/tmp/sim-logs ./sim/run.sh
#                                         where the per-scenario logs go
#   SIM_SCENARIO_TIMEOUT=300 ./sim/run.sh
#                                         seconds a single scenario may run
#
# Every scenario gets a fresh container with no network. The only thing written
# to the host is the log directory, and its path is printed on stdout.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

RUNTIME=${SIM_RUNTIME:-}
if [[ -z $RUNTIME ]]; then
    for candidate in docker podman; do
        if command -v "$candidate" >/dev/null 2>&1; then
            RUNTIME=$candidate
            break
        fi
    done
fi
if [[ -z ${RUNTIME:-} ]]; then
    echo "sim: need docker or podman (or set SIM_RUNTIME)" >&2
    exit 1
fi

# One tag per worktree: two checkouts running the sim at once must not build
# into, or run from, each other's image. The hash separates two worktrees whose
# leaf directory name happens to match; the slug drops any leading dot or dash
# and falls back to `worktree`, so the tag is valid whatever the directory is
# called.
slug=$(printf %s "${PWD##*/}" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-40 | sed 's/^[.-]*//')
[[ -n $slug ]] || slug=worktree
IMAGE=${SIM_IMAGE:-aepm-sim:"$slug"-$(printf %s "$PWD" | sha256sum | cut -c1-8)}

SIM_SCENARIO_TIMEOUT=${SIM_SCENARIO_TIMEOUT:-300}

LOG_DIR=${SIM_LOG_DIR:-sim-logs/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$LOG_DIR"
LOG_DIR=$(realpath "$LOG_DIR")
echo "sim: logs: $LOG_DIR"
build_log=$LOG_DIR/build.log

# A host whose BuildKit cannot create the build sandbox fails before the first
# instruction, and that is a harness fault, not a failing scenario. Retry once
# with the classic builder, which is the one path here that gets `--network
# host`, on the build only. Scenarios never get it; see assert_no_network.
build_image() {
    local retry_log=$LOG_DIR/build-retry.log reason='' status=0

    set +e
    "$RUNTIME" build "${no_cache[@]}" -f sim/Dockerfile -t "$IMAGE" . 2>&1 | tee "$build_log"
    status=${PIPESTATUS[0]}
    set -e
    if ((status == 0)); then
        echo "sim: build: ok with the host's default builder (log: $build_log)"
        return 0
    fi

    # Only a BuildKit that cannot run at all is retried. A Dockerfile error is a
    # real error and must not be papered over by a second builder.
    # Docker names the two veth endpoints, so the words are not adjacent:
    # `failed to add the host (veth1a2b) <=> sandbox (veth3c4d) pair
    # interfaces`. The literal form matched nothing from Docker 24 on, which
    # made this retry dead code on exactly the hosts it exists for.
    if grep -Eq 'failed to add the host.*<=> sandbox.*pair interfaces' "$build_log"; then
        reason='BuildKit cannot create the build sandbox'
    elif grep -q 'BuildKit is enabled but the buildx component is missing' "$build_log"; then
        reason='BuildKit is enabled but buildx is unavailable'
    fi
    if [[ -z $reason ]]; then
        printf 'sim: build: FAILED with the default builder, and this is not a BuildKit fault; not retrying (log: %s)\n' \
            "$build_log" >&2
        return "$status"
    fi

    printf 'sim: build: %s; retrying once with DOCKER_BUILDKIT=0 --network host, build only\n' \
        "$reason" >&2
    set +e
    DOCKER_BUILDKIT=0 "$RUNTIME" build "${no_cache[@]}" --network host \
        -f sim/Dockerfile -t "$IMAGE" . 2>&1 | tee "$retry_log"
    status=${PIPESTATUS[0]}
    set -e
    if ((status != 0)); then
        printf 'sim: build: FAILED on the DOCKER_BUILDKIT=0 retry (log: %s)\n' "$retry_log" >&2
        return "$status"
    fi
    echo "sim: build: ok on the DOCKER_BUILDKIT=0 --network host retry (log: $retry_log)"
}

build_only=0
no_cache=()
while [[ ${1:-} == --* ]]; do
    case $1 in
    --build-only) build_only=1 ;;
    --no-cache) no_cache=(--no-cache) ;;
    *)
        echo "sim: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
done

scenarios=()
if (($# > 0)); then
    scenarios=("$@")
else
    while IFS= read -r file; do
        scenarios+=("$file")
    done < <(find sim/scenarios -maxdepth 1 -name '*.sh' | sort)
fi

# Scenario numbers are a shared namespace across sim/ (the container suite and
# the VM suite), so a collision is refused here, before the build and before any
# container runs.
./sim/check-scenario-numbers.sh "${scenarios[@]}"

if ((build_only)); then
    build_image
    exit 0
fi

if ((${#scenarios[@]} == 0)); then
    echo "sim: no scenarios found" >&2
    exit 1
fi

build_image

# The scenario argv is asserted, not trusted. `--network` appears once outside
# the build, as `none`; a future edit that copies the build's `--network host`
# into the run, or a `# sim-run-args:` header that adds it, fails here instead
# of silently giving every scenario the network.
assert_no_network() {
    local i saw=0
    for ((i = 0; i < ${#run_args[@]}; i++)); do
        case ${run_args[i]} in
            --network=none) saw=1 ;;
            --network=*)
                printf 'sim: refusing to run: %s is not --network none\n' \
                    "${run_args[i]}" >&2
                exit 1
                ;;
            --network)
                if [[ ${run_args[i + 1]:-} != none ]]; then
                    printf 'sim: refusing to run: --network %s is not none\n' \
                        "${run_args[i + 1]:-}" >&2
                    exit 1
                fi
                saw=1
                ;;
        esac
    done
    if ((saw == 0)); then
        printf 'sim: refusing to run: scenario argv has no --network none\n' >&2
        exit 1
    fi
}

rc=0
for scenario in "${scenarios[@]}"; do
    if [[ ! -f $scenario ]]; then
        echo "sim: missing scenario: $scenario" >&2
        rc=1
        continue
    fi

    name="sim-$(basename "${scenario%.sh}")-$$"
    log="$LOG_DIR/$(basename "${scenario%.sh}").log"
    echo "=== $scenario ==="
    mount=(-v "$(realpath "$scenario"):/scenario.sh:ro")
    if [[ -n ${SIM_BINARY:-} ]]; then
        mount+=(-v "$(realpath "$SIM_BINARY"):/usr/local/bin/aepm:ro")
    fi

    # A scenario asks for extra container flags with a header comment, e.g.
    #   # sim-run-args: --tmpfs /var/cache/pacman/pkg:size=1m
    # Values must not contain spaces. A fault-injection scenario uses this to
    # get a filesystem it can fill without changing another scenario's.
    extra=()
    read -ra extra < <(sed -n 's/^# sim-run-args: //p' "$scenario") || true

    run_args=(--name "$name" --network none "${mount[@]}" "${extra[@]}")
    assert_no_network

    # The timeout covers the container's whole life, not one command in it: a
    # scenario that blocks forever fails with its own name and elapsed seconds
    # instead of holding the CI job until the job-level timeout.
    started=$(date +%s)
    set +e
    timeout -k 10 "$SIM_SCENARIO_TIMEOUT" \
        "$RUNTIME" run --rm "${run_args[@]}" \
        --entrypoint /bin/bash \
        "$IMAGE" /scenario.sh 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
    set -e
    elapsed=$(($(date +%s) - started))

    case $status in
        0)
            echo "sim: PASS: $scenario (${elapsed}s, log: $log)"
            ;;
        124 | 137)
            printf 'sim: TIMEOUT: %s did not finish within %ss (elapsed %ss, exit %s, log: %s)\n' \
                "$scenario" "$SIM_SCENARIO_TIMEOUT" "$elapsed" "$status" "$log" >&2
            "$RUNTIME" rm -f "$name" >/dev/null 2>&1 || true
            rc=1
            ;;
        *)
            printf 'sim: FAIL: %s exited %s (log: %s)\n' \
                "$scenario" "$status" "$log" >&2
            rc=1
            ;;
    esac
done

exit "$rc"
