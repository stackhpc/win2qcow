"""qmp.py <name> powerdown|quit|status|index|shot [out.png]

Talks to a test VM started by start.sh through QEMU's QMP port. Each VM name
gets a fixed index (its line in $VMTEST_DIR/ports), so its ports stay the
same: QMP 4450+index, VNC display 80+index. "shot" saves a screenshot to
$VMTEST_DIR/<name>.png by default (PNG with Pillow installed, else PPM).
"""
import json
import os
import pathlib
import socket
import sys

repo = pathlib.Path(__file__).resolve().parents[2]
vmdir = pathlib.Path(os.environ.get("VMTEST_DIR", repo / ".cache" / "vmtest"))
vmdir.mkdir(parents=True, exist_ok=True)


def index(name):
    ports = vmdir / "ports"
    names = ports.read_text().split() if ports.exists() else []
    if name not in names:
        names.append(name)
        ports.write_text("\n".join(names) + "\n")
    return names.index(name)


def connect(name):
    s = socket.create_connection(("127.0.0.1", 4450 + index(name)), timeout=30)
    f = s.makefile("rw")
    f.readline()

    def call(execute, **args):
        f.write(json.dumps({"execute": execute, "arguments": args} if args else {"execute": execute}) + "\n")
        f.flush()
        while True:
            r = json.loads(f.readline())
            if "return" in r or "error" in r:
                return r
    call("qmp_capabilities")
    return call


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    name, cmd = sys.argv[1], sys.argv[2]
    if cmd == "index":
        print(index(name))
    elif cmd == "powerdown":
        print(connect(name)("system_powerdown"))
    elif cmd == "quit":
        print(connect(name)("quit"))
    elif cmd == "status":
        print(connect(name)("query-status")["return"]["status"])
    elif cmd == "shot":
        out = pathlib.Path(sys.argv[3] if len(sys.argv) > 3 else vmdir / f"{name}.png").resolve()
        ppm = out.with_suffix(".ppm")
        connect(name)("screendump", filename=str(ppm))
        try:
            from PIL import Image
        except ImportError:
            print(ppm)
            return
        Image.open(ppm).save(out)
        ppm.unlink()
        print(out)
    else:
        sys.exit(__doc__)


main()
