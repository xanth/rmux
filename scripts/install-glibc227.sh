#!/bin/sh
# Temporary compatibility build from RMUX v0.10.0, with its default web features.
set -eu

fail() { printf 'rmux install: %s\n' "$*" >&2; exit 1; }

case "$(uname -s):$(uname -m)" in
  Linux:x86_64) ;;
  *) fail 'this package requires Linux x86_64' ;;
esac
libc_version="$(getconf GNU_LIBC_VERSION 2>/dev/null)" ||
  fail 'could not identify glibc'
case "$libc_version" in
  'glibc 2.'*)
    minor="${libc_version#glibc 2.}"
    minor="${minor%%.*}"
    case "$minor" in ''|*[!0-9]*) fail 'unrecognized glibc version';; esac
    [ "$minor" -ge 27 ] || fail 'glibc 2.27 or newer is required'
    ;;
  *) fail 'this package requires glibc 2.27 or newer' ;;
esac
for tool in curl tar bash; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
if command -v sha256sum >/dev/null 2>&1; then
  checksum_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  checksum_tool=shasum
else
  fail 'sha256sum or shasum is required'
fi

base_url=https://github.com/Helvesec/rmux/releases/download/support-glibc-2.27-20261024
package=rmux-0.10.0-linux-x86_64-glibc227
archive="$package.tar.gz"
expected_sha256=09c9921fa8ee3d79aca862653f6438cb16fc414cdd3a057922ab60464f14dafd
prefix="${RMUX_INSTALL_PREFIX:-$HOME/.local}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/rmux-glibc227.XXXXXX")"
trap 'rm -rf "$work_dir"' 0
trap 'exit 130' INT
trap 'exit 143' HUP TERM
curl -fsSL "$base_url/$archive" -o "$work_dir/$archive"
(
  cd "$work_dir"
  if [ "$checksum_tool" = sha256sum ]; then
    printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum -c -
  else
    printf '%s  %s\n' "$expected_sha256" "$archive" | shasum -a 256 -c -
  fi
)
tar --no-same-owner -xzf "$work_dir/$archive" -C "$work_dir"
bash "$work_dir/$package/install.sh" --prefix "$prefix"
printf '\nInstalled RMUX for glibc 2.27. Start sharing with:\n%s/bin/rmux web-share --tunnel-provider localhost-run\n' "$prefix"
