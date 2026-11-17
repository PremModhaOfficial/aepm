# syntax=docker/dockerfile:1
#
# Simulation image: a disposable Arch system with a local pacman repo and a
# fake AUR helper. Scenarios run with --network none, so nothing here can reach
# the internet or the host.

FROM archlinux:base-devel AS builder
# Rust from the Arch repo, not rustup: the point is a binary that matches the
# container's glibc.
# -Syu, not -Sy: the base image can be weeks old, and a partial upgrade in a
# rolling-release distro is exactly the failure this project documents.
RUN pacman -Syu --noconfirm --needed rust
WORKDIR /src
# Manifest first so dependency compilation survives src-only changes.
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked --features sim-hooks

FROM archlinux:base-devel

# Phase 2: a non-root user with exactly one NOPASSWD command. No blanket sudo,
# no wildcards. The visudo check makes a malformed rule fail the build, not a
# scenario.
RUN pacman -Syu --noconfirm --needed sudo pacman-contrib rust git \
    && useradd --create-home --shell /bin/bash builder \
    && printf 'builder ALL=(root) NOPASSWD: /usr/bin/pacman -Syuw --noconfirm\n' > /etc/sudoers.d/sim \
    && chmod 0440 /etc/sudoers.d/sim \
    && visudo -cf /etc/sudoers.d/sim \
    && mkdir -p /etc/sim /etc/pacman.d \
    && printf '[aurto]\nServer = file:///srv/empty-repo\n' > /etc/pacman.d/aurto \
    && touch /var/log/sim-yay.log /var/log/sim-yay-build.log \
        /var/log/sim-systemctl.log /var/log/sim-journalctl.log \
        /var/log/sim-loginctl.log /var/log/sim-aurto.log \
        /var/log/sim-paccache.log /var/log/sim-pacdiff.log \
        /var/log/sim-sudo.log \
        /var/log/sim-snapper.log \
    && chmod 0666 /var/log/sim-*.log

# The install scenario runs as a normal user and cannot prompt for a password.
# A real yay escalates for its repo upgrade; the simulation gives it exactly one
# allowed command. The helper takes no arguments and always performs
# `pacman -Syu --noconfirm`, and the sudoers rule names only that helper, not
# pacman itself, so the harness cannot accept a direct pacman escalation.
COPY sim/sim-upgrade /usr/local/bin/sim-upgrade
RUN useradd --create-home --shell /bin/bash installer \
    && chmod 755 /usr/local/bin/sim-upgrade \
    && printf 'installer ALL=(root) NOPASSWD: /usr/local/bin/sim-upgrade ""\n' >> /etc/sudoers.d/sim \
    && visudo -cf /etc/sudoers.d/sim

# Replace mirrors with the offline sim repo. Done after the builder stage so
# only runtime has no network.
COPY sim/pacman.conf /etc/pacman.conf
COPY sim/yay /usr/local/bin/yay
COPY sim/make-repo.sh /usr/local/bin/make-repo.sh
COPY sim/make-pkg.sh /usr/local/bin/make-pkg.sh
COPY sim/lib.sh /usr/local/lib/sim/lib.sh
COPY sim/stubs/ /usr/local/bin/
COPY sim/fixtures /usr/local/lib/sim/fixtures
RUN chmod 755 /usr/local/bin/yay /usr/local/bin/make-repo.sh \
        /usr/local/bin/make-pkg.sh \
        /usr/local/bin/systemctl /usr/local/bin/journalctl \
        /usr/local/bin/loginctl /usr/local/bin/aurto \
        /usr/local/bin/paccache /usr/local/bin/pacdiff /usr/local/bin/sudo \
        /usr/local/bin/snapper \
    && /usr/local/bin/make-repo.sh

COPY --from=builder /src/target/release/aepm /usr/local/bin/aepm

# The packaging scenario runs a real `makepkg` against the checkout this image
# was built from. pkg-src is what the PKGBUILD's git source would clone;
# pkg-repo is an AUR checkout, PKGBUILD plus the .install it names and no
# Cargo.toml in the parse directory. Scenarios have no network: the scenario
# makes pkg-src a local git repo, points the github URL at it, and the builder
# stage's crate registry lets `cargo build --locked` run offline.
COPY Cargo.toml Cargo.lock LICENSE-MIT LICENSE-APACHE README.md \
    /usr/local/lib/sim/pkg-src/
COPY packaging/ /usr/local/lib/sim/pkg-src/packaging/
COPY --from=builder /src/src/ /usr/local/lib/sim/pkg-src/src/
COPY PKGBUILD /usr/local/lib/sim/pkg-repo/
COPY packaging/aepm.install /usr/local/lib/sim/pkg-repo/packaging/
COPY --from=builder /root/.cargo/registry/ /home/builder/.cargo/registry/
RUN chown -R builder:builder /home/builder/.cargo

WORKDIR /root
