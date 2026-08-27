#!/bin/sh
# ax installer — downloads the latest ax release from GitHub Releases,
# verifies its sha256, and installs the binary into ~/.ax/bin.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/doriangironde/ax/main/install.sh | sh
#
# Settings:
#   AX_VERSION          pin a release tag (default: latest)
#   AX_INSTALL_DIR      install directory (default: ~/.ax/bin)
set -eu

repo="doriangironde/ax"

os="$(uname -s 2>/dev/null || echo unknown)"
machine="$(uname -m 2>/dev/null || echo unknown)"
case "$os" in
    Darwin) platform="macos" ;;
    Linux) platform="linux" ;;
    *) echo "ax: unsupported OS: $os (installer covers macos and linux)" >&2; exit 1 ;;
esac
case "$machine" in
    arm64 | aarch64)
        # The release pipeline names macos arm64 assets "arm64" and linux
        # ones "aarch64".
        if [ "$os" = "Darwin" ]; then arch="arm64"; else arch="aarch64"; fi
        ;;
    x86_64 | amd64) arch="x86_64" ;;
    *) echo "ax: unsupported architecture: $machine" >&2; exit 1 ;;
esac

if command -v curl >/dev/null 2>&1; then
    fetch_sh="curl -fsSL"
else
    fetch_sh="wget -qO-"
fi

tag="${AX_VERSION:-}"
if [ -z "$tag" ]; then
    latest="$($fetch_sh "https://api.github.com/repos/$repo/releases/latest")" || {
        echo "ax: could not fetch the latest release metadata" >&2
        exit 1
    }
    tag="$(printf '%s' "$latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$tag" ]; then
        echo "ax: could not parse the latest release tag" >&2
        exit 1
    fi
fi

archive="ax-$platform-$arch.tar.gz"
base_url="https://github.com/$repo/releases/download/$tag"
echo "ax: installing $tag ($platform $arch) into \${AX_INSTALL_DIR:-~/.ax/bin}"

tmp="$(mktemp -d 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/ax-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

if curl --version >/dev/null 2>&1; then
    curl -fsSL "$base_url/$archive" -o "$tmp/ax.tar.gz"
    curl -fsSL "$base_url/$archive.sha256" -o "$tmp/ax.tar.gz.sha256"
else
    wget -q "$base_url/$archive" -O "$tmp/ax.tar.gz"
    wget -q "$base_url/$archive.sha256" -O "$tmp/ax.tar.gz.sha256"
fi

if command -v shasum >/dev/null 2>&1; then
    sha_tool="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    sha_tool="sha256sum"
else
    sha_tool="openssl dgst -sha256"
fi
expected="$($sha_tool "$tmp/ax.tar.gz" | sed 's/ .*//' | tr '[:upper:]' '[:lower:]')"
want="$(sed 's/^\([^ ]*\).*/\1/' "$tmp/ax.tar.gz.sha256" | tr '[:upper:]' '[:lower:]')"
if [ "$expected" != "$want" ]; then
    echo "ax: checksum verification failed (expected $want, got $expected)" >&2
    exit 1
fi
echo "ax: sha256 verified"

tar -xzf "$tmp/ax.tar.gz" -C "$tmp"
if [ ! -f "$tmp/ax" ]; then
    echo "ax: the release archive does not contain the ax binary" >&2
    exit 1
fi

dest="${AX_INSTALL_DIR:-$HOME/.ax/bin}"
mkdir -p "$dest"
install -m 0755 "$tmp/ax" "$dest/ax"
echo "ax: installed $( "$dest/ax" --version ) at $dest/ax"

case ":$PATH:" in
    *":$dest:"*) ;;
    *)
        rc="${AX_SHELL_RC:-}"
        if [ -z "$rc" ]; then
            if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
                rc="$HOME/.zshrc"
            elif [ -f "$HOME/.bashrc" ]; then
                rc="$HOME/.bashrc"
            fi
        fi
        if [ -n "$rc" ]; then
            echo "export PATH=\"$dest:\$PATH\"" >> "$rc"
            echo "ax: added $dest to PATH in $rc"
        else
            echo "ax: add $dest to your PATH (export PATH=\"$dest:\$PATH\")"
        fi
        ;;
esac

echo "ax: run 'ax --help' to get started, or 'ax login' to sign in."