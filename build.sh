#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SUFFIX=debforge
OPTIONS='
CONFIG_HZ_1000=y
CONFIG_HZ=1000
CONFIG_PREEMPT=y
CONFIG_PREEMPT_DYNAMIC=y
# CONFIG_RUST is not set
CONFIG_MODULE_COMPRESS_ZSTD=y
# CONFIG_MODULE_COMPRESS_XZ is not set
CONFIG_CPU_IDLE_GOV_TEO=y
CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y
CONFIG_IRQ_TIME_ACCOUNTING=y
'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$PROJECT_DIR/$(basename "${BASH_SOURCE[0]}")"
PATCHES_DIR="$PROJECT_DIR/patches"
CACHE_DIR="$PROJECT_DIR/cache"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/output"
SOURCE_DIR="$BUILD_DIR/linux"
BUILD_LOG="$BUILD_DIR/build.log"
REQUIRED_PACKAGES="bc bison build-essential cpio debhelper dpkg-dev dwarves fakeroot flex kmod \
libdw-dev libelf-dev libssl-dev patch python3 rsync xz-utils zstd"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo ./build.sh [--suffix=NAME] [--install]

Builds the newest kernel from Debian backports with the OPTIONS in build.sh
and the patches in patches/, as Debian packages in output/.

  --suffix=NAME   name added to the kernel release (default: $DEFAULT_SUFFIX)
                  --suffix=desktop gives uname -r like 7.2.6-desktop
  --install       install the kernel after building it
  -h, --help      show this help
EOF
}

parse_arguments() {
    SUFFIX_NAME="$DEFAULT_SUFFIX"
    INSTALL_AFTER_BUILD=no
    while [ $# -gt 0 ]; do
        case "$1" in
            --suffix=*) SUFFIX_NAME="${1#--suffix=}" ;;
            --suffix)
                [ $# -ge 2 ] || die "--suffix needs a value, for example --suffix=desktop"
                SUFFIX_NAME="$2"
                shift
                ;;
            --install) INSTALL_AFTER_BUILD=yes ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'ERROR: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
        esac
        shift
    done
    SUFFIX_NAME="${SUFFIX_NAME#-}"
    [[ $SUFFIX_NAME =~ ^[a-z0-9][a-z0-9.+-]*$ ]] \
        || die "invalid suffix '$SUFFIX_NAME': use lowercase letters, digits, '.', '+' or '-'"
    SUFFIX="-$SUFFIX_NAME"
}

require_sudo() {
    if [ "$(id -u)" != 0 ]; then
        die "debforge-kernel installs packages, run it with sudo:
       sudo $0${ORIGINAL_ARGUMENTS:+ $ORIGINAL_ARGUMENTS}"
    fi
    if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = root ]; then
        die "run debforge-kernel with sudo from your normal user account, not from a root shell"
    fi
}

install_dependencies() {
    local package_name missing_packages=()
    for package_name in $REQUIRED_PACKAGES; do
        if [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$package_name" 2>/dev/null || true)" != ii* ]]; then
            missing_packages+=("$package_name")
        fi
    done
    [ ${#missing_packages[@]} -gt 0 ] || return 0
    log "installing missing build packages: ${missing_packages[*]}"
    local install_command=(env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}")
    "${install_command[@]}" || { apt-get update && "${install_command[@]}"; } \
        || die "could not install: ${missing_packages[*]}"
}

version_in_suite() {
    { apt-cache madison "$1" 2>/dev/null || true; } \
        | awk -F'|' -v suite=" $2/" 'index($3, suite) { gsub(/ /, "", $2); print $2; exit }'
}

latest_series_in_suite() {
    local package_name
    { apt-cache search --names-only '^linux-source-[0-9]+\.[0-9]+$' 2>/dev/null || true; } \
        | awk '{print $1}' \
        | while read -r package_name; do
              if [ -n "$(version_in_suite "$package_name" "$1")" ]; then
                  printf '%s\n' "${package_name#linux-source-}"
              fi
          done | sort -V | tail -n 1
}

resolve_kernel() {
    local debian_codename
    debian_codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')"
    [ -n "$debian_codename" ] || die "cannot read VERSION_CODENAME from /etc/os-release"
    BACKPORTS_SUITE="$debian_codename-backports"
    KERNEL_SERIES="$(latest_series_in_suite "$BACKPORTS_SUITE")"
    if [ -z "$KERNEL_SERIES" ]; then
        log "no kernel source found in $BACKPORTS_SUITE, refreshing the package lists"
        apt-get update || true
        KERNEL_SERIES="$(latest_series_in_suite "$BACKPORTS_SUITE")"
    fi
    [ -n "$KERNEL_SERIES" ] || die "no linux-source package found in $BACKPORTS_SUITE, enable it with:
       echo 'deb http://deb.debian.org/debian $BACKPORTS_SUITE main' | sudo tee /etc/apt/sources.list.d/$BACKPORTS_SUITE.list
       and run debforge-kernel again"
    DEBIAN_VERSION="$(version_in_suite "linux-source-$KERNEL_SERIES" "$BACKPORTS_SUITE")"
    dpkg --validate-version "$DEBIAN_VERSION$SUFFIX" 2>/dev/null \
        || die "'$DEBIAN_VERSION$SUFFIX' is not a valid Debian version, choose another suffix"
}

download_package() {
    local package_spec="$1" file_name
    file_name="$(apt-get download --print-uris "$package_spec" 2>/dev/null | awk 'NR == 1 {print $2}')"
    [ -n "$file_name" ] || die "apt cannot locate $package_spec"
    if [ ! -f "$CACHE_DIR/$file_name" ]; then
        log "downloading $file_name" >&2
        (cd "$CACHE_DIR" && apt-get download "$package_spec" >&2) || die "apt-get download $package_spec failed"
    fi
    printf '%s' "$CACHE_DIR/$file_name"
}

build_kernel() {
    local package_version="$DEBIAN_VERSION$SUFFIX"
    local architecture source_package config_package options_file patch_file option_line option_name
    local failed_options=0 jobs package_file package_name result_dir="$OUTPUT_DIR/$DEBIAN_VERSION$SUFFIX"
    architecture="$(dpkg --print-architecture)"

    mkdir -p "$CACHE_DIR"
    source_package="$(download_package "linux-source-$KERNEL_SERIES=$DEBIAN_VERSION")"
    config_package="$(download_package "linux-config-$KERNEL_SERIES=$DEBIAN_VERSION")"

    log "extracting the kernel source"
    rm -rf -- "$BUILD_DIR"
    mkdir -p "$SOURCE_DIR"
    dpkg-deb --fsys-tarfile "$source_package" \
        | tar -xO --wildcards '*/linux-source-*.tar.xz' \
        | tar -xJ -C "$SOURCE_DIR" --strip-components=1
    [ -f "$SOURCE_DIR/Makefile" ] || die "no kernel source found in $source_package"

    shopt -s nullglob
    local patch_files=("$PATCHES_DIR"/*.patch)
    shopt -u nullglob
    for patch_file in "${patch_files[@]}"; do
        log "applying $(basename "$patch_file")"
        patch -d "$SOURCE_DIR" -p1 -N -s --no-backup-if-mismatch -i "$patch_file" \
            || die "$(basename "$patch_file") does not apply, build stopped"
        [ -z "$(find "$SOURCE_DIR" -name '*.rej' -print -quit)" ] \
            || die "$(basename "$patch_file") left a rejected hunk, build stopped"
    done

    log "configuring"
    dpkg-deb --fsys-tarfile "$config_package" \
        | tar -xO --wildcards "*/config.${architecture}_none_${architecture}.xz" \
        | xz -dc >"$SOURCE_DIR/.config"
    [ -s "$SOURCE_DIR/.config" ] || die "no $architecture config found in $config_package"

    options_file="$BUILD_DIR/options.config"
    printf '%s\n' "$OPTIONS" | sed '/^[[:space:]]*$/d' >"$options_file"

    cd "$SOURCE_DIR"
    ./scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
    ./scripts/kconfig/merge_config.sh -m .config "$options_file" >/dev/null
    make -s olddefconfig

    log "verifying .config"
    while IFS= read -r option_line; do
        if [[ $option_line =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
            option_name="${BASH_REMATCH[1]}"
            if grep -q "^$option_name=" .config; then
                printf 'ERROR: %s should be off, .config has: %s\n' "$option_name" "$(grep "^$option_name=" .config)" >&2
                failed_options=1
            fi
        elif [[ $option_line =~ ^(CONFIG_[A-Za-z0-9_]+)= ]]; then
            if ! grep -qxF "$option_line" .config; then
                option_name="${BASH_REMATCH[1]}"
                printf 'ERROR: wanted %s, .config has: %s\n' "$option_line" \
                    "$(grep -E "^(# )?${option_name}[= ]" .config || echo 'nothing')" >&2
                failed_options=1
            fi
        else
            die "invalid line in OPTIONS: $option_line"
        fi
    done <"$options_file"
    [ "$failed_options" = 0 ] || die "some OPTIONS did not make it into .config, build stopped"

    jobs="$(nproc)"
    log "building $package_version with $jobs jobs, log in ${BUILD_LOG#"$PROJECT_DIR"/}"
    if ! DEB_BUILD_PROFILES="pkg.linux-upstream.nokerneldbg" \
            make -j"$jobs" bindeb-pkg LOCALVERSION="$SUFFIX" KDEB_PKGVERSION="$package_version" 2>&1 \
            | tee "$BUILD_LOG"; then
        grep -iE 'error' "$BUILD_LOG" | tail -n 20 >&2 || true
        die "build failed, full log in $BUILD_LOG"
    fi

    shopt -s nullglob
    local built_packages=("$BUILD_DIR"/*.deb)
    shopt -u nullglob
    [ ${#built_packages[@]} -gt 0 ] || die "the build produced no packages, see $BUILD_LOG"
    rm -rf -- "$result_dir"
    mkdir -p "$result_dir"
    for package_file in "${built_packages[@]}"; do
        package_name="$(dpkg-deb -f "$package_file" Package)"
        if [[ $package_name == *-dbg ]]; then
            rm -f "$package_file"
        else
            mv "$package_file" "$result_dir/"
        fi
    done
}

finish() {
    local result_dir="$OUTPUT_DIR/$DEBIAN_VERSION$SUFFIX" kernel_packages=() kernel_release
    shopt -s nullglob
    kernel_packages=("$result_dir"/linux-image-*.deb "$result_dir"/linux-headers-*.deb)
    shopt -u nullglob
    [ ${#kernel_packages[@]} -gt 0 ] || die "no kernel packages were produced, see $BUILD_LOG"
    kernel_release="$(dpkg-deb -f "${kernel_packages[0]}" Package)"
    kernel_release="${kernel_release#linux-image-}"

    log "built linux $kernel_release, packages in ${result_dir#"$PROJECT_DIR"/}"
    if [ "$INSTALL_AFTER_BUILD" = yes ]; then
        log "installing linux $kernel_release"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${kernel_packages[@]}"
        log "installed, reboot and pick linux $kernel_release in the boot menu if it is not the default"
    else
        printf '    install with:\n      sudo apt install'
        printf ' %s' "${kernel_packages[@]}"
        printf '\n'
    fi
    printf '    remove later with:\n      sudo apt remove linux-image-%s linux-headers-%s\n' "$kernel_release" "$kernel_release"
}

if [ "${DEBFORGE_KERNEL_STAGE:-}" = build ]; then
    build_kernel
    exit 0
fi

ORIGINAL_ARGUMENTS="$*"
parse_arguments "$@"
require_sudo
install_dependencies
resolve_kernel
log "kernel: linux-source-$KERNEL_SERIES $DEBIAN_VERSION from $BACKPORTS_SUITE, suffix $SUFFIX"
log "continuing as $SUDO_USER, nothing is compiled as root"
sudo -u "$SUDO_USER" -H env DEBFORGE_KERNEL_STAGE=build \
    KERNEL_SERIES="$KERNEL_SERIES" DEBIAN_VERSION="$DEBIAN_VERSION" SUFFIX="$SUFFIX" \
    "$SCRIPT_PATH"
finish
