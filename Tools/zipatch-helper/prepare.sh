#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
dest_root="$script_dir/.patched"
checkout="$dest_root/zipatch"
patch_file="$script_dir/patches/0001-join-game-path.patch"
expected_sha="392feaccb2f53974d429a47281309f194958b7dce822fc9a41a036142cf2d874"
crate_url="https://static.crates.io/crates/zipatch/zipatch-1.0.1.crate"

if [[ ! -f "$patch_file" ]]; then
  print -u2 "missing patch: $patch_file"
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

curl -fsSL -o "$workdir/zipatch-1.0.1.crate" "$crate_url"
actual_sha="$(shasum -a 256 "$workdir/zipatch-1.0.1.crate" | awk '{print $1}')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  print -u2 "zipatch-1.0.1.crate checksum mismatch"
  print -u2 "expected $expected_sha"
  print -u2 "got      $actual_sha"
  exit 1
fi

tar -xzf "$workdir/zipatch-1.0.1.crate" -C "$workdir"
if [[ ! -d "$workdir/zipatch-1.0.1" ]]; then
  print -u2 "zipatch-1.0.1.crate did not contain zipatch-1.0.1/"
  exit 1
fi

patch -p1 -d "$workdir/zipatch-1.0.1" -i "$patch_file"

rm -rf "$dest_root"
mkdir -p "$dest_root"
mv "$workdir/zipatch-1.0.1" "$checkout"
