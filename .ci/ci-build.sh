#!/bin/bash

set -eo pipefail

# AppVeyor and Drone Continuous Integration for MSYS2
# Author: Renato Silva <br.renatosilva@gmail.com>
# Author: Qian Hong <fracting@gmail.com>

DIR="$( cd "$( dirname "$0" )" && pwd )"

# Configure
source "$DIR/ci-library.sh"
mkdir artifacts
git remote add upstream 'https://github.com/MSYS2/MSYS2-packages'
git fetch --quiet upstream
# reduce time required to install packages by disabling pacman's disk space checking
sed -i 's/^CheckSpace/#CheckSpace/g' /etc/pacman.conf

pacman --noconfirm -Fy

# Detect
list_packages || failure 'Could not detect changed files'
message 'Processing changes'
test -z "${packages}" && success 'No changes in package recipes'

# Build
message 'Building packages' "${packages[@]}"

message 'Adding an empty local repository'
repo-add $PWD/artifacts/ci.db.tar.gz
sed -i '1s|^|[ci]\nServer = file://'"$PWD"'/artifacts/\nSigLevel = Never\n|' /etc/pacman.conf
pacman -Sy

# Remove git and python
pacman -R --recursive --unneeded --noconfirm --noprogressbar git python

# Enable linting
export MAKEPKG_LINT_PKGBUILD=1

message 'Building packages'
for package in "${packages[@]}"; do
    echo "::group::[build] ${package}"
    execute 'Clear cache' pacman -Scc --noconfirm
    execute 'Fetch keys' "$DIR/fetch-validpgpkeys.sh"
    execute 'Building binary' makepkg --noconfirm --noprogressbar --nocheck --syncdeps --rmdeps --cleanbuild
    repo-add $PWD/artifacts/ci.db.tar.gz $PWD/$package/*.pkg.tar.*
    pacman -Sy
    cp $PWD/$package/*.pkg.tar.* $PWD/artifacts
    echo "::endgroup::"

    echo "::group::[dll check] ${package}"
    execute 'Checking dll depencencies' list_dll_deps ./pkg
    execute 'Checking dll bases' list_dll_bases ./pkg
    echo "::endgroup::"

    cd "$package"
    for pkg in *.pkg.tar.*; do
        pkgname="$(echo "$pkg" | rev | cut -d- -f4- | rev)"
        echo "::group::[install] ${pkgname}"
        grep -qFx "${package}" "$DIR/ci-dont-install-list.txt" || pacman --noprogressbar --upgrade --noconfirm $pkg
        echo "::endgroup::"

        echo "::group::[meta-diff] ${pkgname}"
        message "Package info diff for ${pkgname}"
        diff -Nur <(pacman -Si ${MSYSTEM,,}/"${pkgname}") <(pacman -Qip "${pkg}") || true
        echo "::endgroup::"

        echo "::group::[file-diff] ${pkgname}"
        message "File listing diff for ${pkgname}"
        diff -Nur <(pacman -Fl ${MSYSTEM,,}/"$pkgname" | sed -e 's|^[^ ]* |/|' | sort) <(pacman -Ql "$pkgname" | sed -e 's|^[^/]*||' | sort) || true
        echo "::endgroup::"

        echo "::group::[uninstall] ${pkgname}"
        message "Uninstalling $pkgname"
        grep -qFx "${package}" "$DIR/ci-dont-install-list.txt" || pacman -R --recursive --unneeded --noconfirm --noprogressbar "$pkgname"
        echo "::endgroup::"
    done
    cd - > /dev/null

    rm -f "${package}"/*.pkg.tar.*
    unset package
done
success 'All packages built successfully'

cd artifacts
execute 'SHA-256 checksums' sha256sum *
