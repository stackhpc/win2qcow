#!/bin/bash
# mkcd.sh <name> [user-data file]
#
# Builds an OpenStack config drive ($VMTEST_DIR/<name>.iso, label config-2)
# with a fresh instance uuid, hostname <name>, an Admin password and a DHCP
# network_data.json. The password is in $VMTEST_DIR/admin_pass (created once).
set -euo pipefail
. "$(dirname "$0")/common.sh"
name=${1:?usage: mkcd.sh <name> [user-data]}; userdata=${2:-}
d=$(mktemp -d -p "$VMTEST_DIR")
trap 'rm -rf "${d:?}"' EXIT
mkdir -p "$d/openstack/latest"
[ -f "$VMTEST_DIR/admin_pass" ] || (umask 077; echo "Vt-$(openssl rand -base64 12)!" > "$VMTEST_DIR/admin_pass")
python3 - "$d/openstack/latest" "$name" "$(cat "$VMTEST_DIR/admin_pass")" <<'PY'
import json, sys, uuid
d, host, pw = sys.argv[1:]
json.dump({"uuid": str(uuid.uuid4()), "name": host, "hostname": host, "availability_zone": "nova",
           "launch_index": 0, "project_id": "test", "meta": {"admin_pass": pw}, "public_keys": {}},
          open(f"{d}/meta_data.json", "w"))
json.dump({"links": [{"id": "tap0", "type": "phy", "ethernet_mac_address": "52:54:00:12:34:57", "mtu": 1500}],
           "networks": [{"id": "net0", "link": "tap0", "type": "ipv4_dhcp", "network_id": "n0"}], "services": []},
          open(f"{d}/network_data.json", "w"))
PY
if [ -n "$userdata" ]; then cp "$userdata" "$d/openstack/latest/user_data"; fi
xorriso -as mkisofs -quiet -V config-2 -J -R -o "$VMTEST_DIR/$name.iso" "$d" 2>/dev/null
echo "$VMTEST_DIR/$name.iso"
