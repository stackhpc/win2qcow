#!/usr/bin/env bash
# Build the image for one hardware variant (a file in variants/).
#
#   scripts/build-variant.sh dell-poweredge-r740xd -var iso_url=... -var iso_checksum=...
#
# Fetches and checks the variant's drivers into drivers/<variant>/, then runs
# packer build with them; the image goes to output-<variant>/ in the repo. Extra arguments go to packer build. Uses .venv/ (see
# README) for Python if it exists.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
variant=${1:?usage: $0 VARIANT [packer build options]}
shift
toml="$repo/variants/$variant.toml"
if [ ! -f "$toml" ]; then
  echo "no such variant: $toml; available:" >&2
  ls "$repo/variants" | sed 's/\.toml$//' >&2
  exit 1
fi

python=${PYTHON:-python3}
[ -x "$repo/.venv/bin/python" ] && python="$repo/.venv/bin/python"

drivers="$repo/drivers/$variant"
"$python" "$repo/scripts/drivers.py" fetch "$toml" --output "$drivers"

# No cd: relative paths in the arguments (e.g. -var iso_url=...) resolve
# against the caller's directory. The template finds its own files itself.
packer init "$repo/windows-11-ironic.pkr.hcl"
packer build \
  -var "vendor_drivers_dir=$drivers" \
  -var "output_directory=$repo/output-$variant" \
  -var "vm_name=windows-11-$variant.qcow2" \
  "$@" "$repo/windows-11-ironic.pkr.hcl"
