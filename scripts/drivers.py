#!/usr/bin/env python3
"""Fetch, extract and check Windows drivers for a hardware variant.

    drivers.py fetch variants/dell-poweredge-r740xd.toml
    drivers.py check-infs DIR
    drivers.py dell-catalog --system-id 0737

`fetch` downloads every package listed in the variant file, verifies its
SHA-256, unpacks it (vendor installers included), keeps only the driver
packages Windows 11 x64 will accept, and writes them to drivers/<variant>/
with a REPORT.md. Pass that directory to Packer as vendor_drivers_dir.

Needs Python 3.11+, 7z (the 7zip package) and, for MSI-wrapped drivers,
pymsi (pip install -r requirements-drivers.txt).
"""

import argparse
import fnmatch
import gzip
import hashlib
import json
import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import tomllib
import urllib.request
import xml.etree.ElementTree as ET
import zlib

REPO = pathlib.Path(__file__).resolve().parent.parent
UNPACK_VERSION = 2  # bump when unpacking changes: cached extractions are keyed on it
HTTP_TIMEOUT = 120  # seconds without data before a download fails
USER_AGENT = "windows-image-build"  # some download sites challenge browser-like agents

# The OS the image runs: Windows 11 25H2, client (product type 1), x64.
TARGET_ARCH = "amd64"
TARGET_VERSION = (10, 0)
TARGET_PRODUCT_TYPE = 1
TARGET_BUILD = 26200
PRODUCT_TYPES = {1: "workstation", 2: "domain controller", 3: "server"}


# ---------------------------------------------------------------------------
# INF parsing
# ---------------------------------------------------------------------------

def read_inf(path):
    data = pathlib.Path(path).read_bytes()
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        text = data.decode("utf-16")
    elif data.startswith(b"\xef\xbb\xbf"):
        text = data[3:].decode("utf-8", "replace")
    elif data[:200].count(b"\x00") > 50:
        text = data.decode("utf-16-le", "replace")
    else:
        text = data.decode("cp1252", "replace")
    sections, current, pending = {}, None, ""
    for raw in text.splitlines():
        line = pending + raw
        pending = ""
        # Strip comments outside double quotes.
        out, quoted = [], False
        for ch in line:
            if ch == '"':
                quoted = not quoted
            elif ch == ";" and not quoted:
                break
            out.append(ch)
        line = "".join(out).strip()
        if line.endswith("\\"):
            pending = line[:-1]
            continue
        if not line:
            continue
        m = re.match(r"^\[([^\]]+)\]$", line)
        if m:
            current = m.group(1).strip().lower()
            sections.setdefault(current, [])
        elif current is not None:
            sections[current].append(line)
    return sections


def version_value(sections, key):
    for line in sections.get("version", []):
        k, _, v = line.partition("=")
        if k.strip().lower() == key.lower():
            return v.strip().strip('"')
    return None


def parse_decoration(dec):
    """NT[arch][.major[.minor[.productType[.suiteMask[.build]]]]] -> dict, or None."""
    m = re.match(r"^NT([A-Za-z0-9]*)((?:\.[^.]*){0,5})$", dec.strip(), re.I)
    if not m:
        return None
    fields = (m.group(2)[1:].split(".") if m.group(2) else [])
    fields += [""] * (5 - len(fields))

    def num(s):
        s = s.strip()
        return int(s, 16) if s.lower().startswith("0x") else (int(s) if s else None)

    try:
        values = [num(f) for f in fields]
    except ValueError:
        return None  # not a valid decoration: Windows ignores it too

    return {"text": dec.strip(), "arch": m.group(1).lower(), "major": values[0], "minor": values[1],
            "product_type": values[2], "suite": values[3], "build": values[4]}


def decoration_status(d):
    """Return (applies, reason) for the target OS."""
    if d["arch"] != TARGET_ARCH:
        return False, f"for {d['arch'] or 'x86'}"
    if d["major"] is not None and (d["major"], d["minor"] or 0) > TARGET_VERSION:
        return False, f"needs Windows {d['major']}.{d['minor']}"
    if d["product_type"] is not None and d["product_type"] != TARGET_PRODUCT_TYPE:
        return False, f"{PRODUCT_TYPES.get(d['product_type'], d['product_type'])} only"
    if d["suite"]:
        return False, f"suite mask {d['suite']:#x}"
    if d["build"] is not None and d["build"] > TARGET_BUILD:
        return False, f"needs build {d['build']}"
    return True, ""


def specificity(d):
    return (d["major"] or 0, d["minor"] or 0, d["product_type"] is not None, d["build"] or 0)


def analyse_inf(path, inbox=False):
    """Describe one INF: does Windows 11 x64 accept it, and for which hardware.

    inbox=True skips the catalog check: Windows' own INFs are signed by system
    catalogs and have no CatalogFile entry."""
    sections = read_inf(path)
    info = {"path": str(path), "class": version_value(sections, "Class"),
            "driver_ver": version_value(sections, "DriverVer"), "applies": False,
            "decoration": None, "reason": "", "hardware_ids": [], "catalog": None}
    catalog = version_value(sections, f"CatalogFile.NT{TARGET_ARCH}") or version_value(sections, "CatalogFile")
    if inbox:
        pass
    elif catalog:
        info["catalog"] = catalog
        if not any(p.name.lower() == catalog.lower() for p in pathlib.Path(path).parent.iterdir()):
            info["reason"] = f"catalog {catalog} missing"
            return info
    else:
        info["reason"] = "unsigned (no CatalogFile)"
        return info
    entries = sections.get("manufacturer", [])
    if not entries:
        info["reason"] = "no [Manufacturer] section"
        return info
    rejected = set()
    for line in entries:
        _, _, rhs = line.partition("=")
        parts = [p.strip() for p in (rhs or line).split(",")]
        base, decorations = parts[0].strip('"'), [p for p in parts[1:] if p]
        best = None
        for dec in decorations:
            d = parse_decoration(dec)
            if not d:
                continue
            ok, why = decoration_status(d)
            if ok and (best is None or specificity(d) > specificity(best)):
                best = d
            elif not ok:
                rejected.add(why)
        if not best:
            continue
        models = sections.get(f"{base}.{best['text']}".lower(), [])
        hwids = []
        for m in models:
            _, _, ids = m.partition("=")
            hwids += [x.strip() for x in ids.split(",")[1:] if x.strip()]
        if hwids:
            info.update(applies=True, decoration=best["text"])
            info["hardware_ids"] += hwids
    if not info["applies"]:
        info["reason"] = "; ".join(sorted(rejected)) or "no x64 models"
    info["hardware_ids"] = sorted(set(h.upper() for h in info["hardware_ids"]))
    return info


# ---------------------------------------------------------------------------
# Unpacking vendor packages
# ---------------------------------------------------------------------------

ARCHIVE_TYPES = {"zip", "cab", "7z", "rar", "gzip", "tar", "iso", "udf", "xar", "wim", "nsis"}
CANDIDATE_SUFFIXES = {"", ".exe", ".zip", ".cab", ".7z", ".pkg", ".msi", ".gz", ".tar"}
OLE_MAGIC = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"


def sevenzip_types(path):
    r = subprocess.run(["7z", "l", "-slt", "-p-", str(path)], capture_output=True, text=True, errors="replace")
    head = r.stdout.split("\n----------\n")[0]
    return [t.strip().lower() for t in re.findall(r"^Type = (.+)$", head, re.M)]


def run(cmd):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, errors="replace")
    return r.returncode == 0, (r.stdout + r.stderr)[-2000:]


# pymsi 0.0.0rc1 fails on MSIs whose shortcuts name an icon missing from the
# Icon table (Emulex's does). Shortcuts don't matter for extraction, so the
# lookup is made tolerant before running pymsi's own command line.
PYMSI_SHIM = """
import importlib, sys
sc = importlib.import_module("pymsi.msi.shortcut")
populate = sc.Shortcut._populate
def tolerant(self, directory_map, component_map, icon_map):
    return populate(self, directory_map, component_map, dict(icon_map, **{self._icon: None} if self._icon and self._icon not in icon_map else {}))
sc.Shortcut._populate = tolerant
from pymsi.__main__ import main
sys.argv = ["pymsi"] + sys.argv[1:]
sys.exit(main())
"""


def extract_msi(msi, out):
    try:
        import pymsi  # noqa: F401
    except ImportError:
        raise SystemExit(f"{msi.name} is an MSI: install pymsi (pip install -r requirements-drivers.txt)")
    ok, log = run([sys.executable, "-c", PYMSI_SHIM, "extract", "--no-strict", "-o", out, msi])
    return ok and pathlib.Path(out).is_dir()


def carve_embedded_msi(exe, out):
    """InstallShield setup.exe files carry the MSI appended to the executable."""
    data = exe.read_bytes()
    at = data.find(OLE_MAGIC, 1024)
    while at != -1:
        if at % 512 == 0 or data[at + 0x1e:at + 0x20] == b"\x09\x00":
            msi = out.with_suffix(".msi")
            msi.write_bytes(data[at:])
            if extract_msi(msi, out):
                msi.unlink()
                return True
            msi.unlink()
        at = data.find(OLE_MAGIC, at + 1)
    return False


IS_MAGIC = bytes([0x13, 0x35, 0x86, 0x07])
IS_SWAP_INVERT = bytes((~((b << 4) | (b >> 4))) & 0xFF for b in range(256))


def is_decode_block(buf, key):
    """One 1024-byte block: each byte is nibble-swapped, XORed with the key
    (cycling from the block start) and inverted."""
    out = bytearray(len(buf))
    for j, k in enumerate(key):
        out[j::len(key)] = buf[j::len(key)].translate(bytes(x ^ k for x in IS_SWAP_INVERT))
    return bytes(out)


def unpack_issetupstream(exe, out):
    """InstallShield "Setup Launcher" executables carry their files (usually an
    MSI) in an obfuscated ISSetupStream: a 46-byte header, then per file a
    24-byte record, the UTF-16 name and the data. The data is XOR-encoded with
    a key derived from the file name, in 1024-byte blocks, then zlib-compressed.
    Same scheme as the open-source ISx extractor."""
    data = exe.read_bytes()
    at = data.find(b"ISSetupStream\0")
    while at != -1:
        try:
            count = struct.unpack_from("<H", data, at + 14)[0]
            if not 0 < count < 1000:  # the string also appears in the launcher's own code
                raise ValueError(count)
            pos, files = at + 46, []
            for _ in range(count):
                name_len, _flags = struct.unpack_from("<II", data, pos)
                size = struct.unpack_from("<I", data, pos + 10)[0]
                name = data[pos + 24:pos + 24 + name_len].decode("utf-16-le")
                if not (0 < name_len < 520 and name.isprintable() and "/" not in name and "\\" not in name):
                    raise ValueError(name)
                files.append((name, data[pos + 24 + name_len:pos + 24 + name_len + size]))
                pos += 24 + name_len + size
        except (struct.error, ValueError, UnicodeDecodeError):
            at = data.find(b"ISSetupStream\0", at + 1)
            continue
        out.mkdir(parents=True, exist_ok=True)
        for name, blob in files:
            key = bytes(c ^ IS_MAGIC[i % 4] for i, c in enumerate(name.encode("latin-1", "replace")))
            plain = b"".join(is_decode_block(blob[i:i + 1024], key) for i in range(0, len(blob), 1024))
            if plain[:1] == b"\x78":
                try:
                    plain = zlib.decompress(plain)
                except zlib.error:
                    pass
            (out / name).write_bytes(plain)
        return True
    return False


def unpack_burn(bundle, folder):
    """WiX Burn bundles: 7-Zip opens the UI container, whose files are named
    u0, u1, ...; the payloads (MSIs, cabs) are in an attached container, a cab
    appended to the executable. Manifest '0' maps both to real names."""
    manifest = folder / "0"
    if not manifest.is_file():
        return
    try:
        root = ET.parse(manifest).getroot()
    except ET.ParseError:
        return
    if not root.tag.endswith("BurnManifest"):
        return
    for c in root.iter():
        if c.tag.endswith("Container") and c.get("Attached") == "yes" and c.get("FileSize"):
            # The container precedes the Authenticode signature at the end of
            # the file; find it by its cab header, whose size field must match.
            size, data = int(c.get("FileSize")), bundle.read_bytes()
            at = data.find(b"MSCF\0\0\0\0")
            while at != -1 and int.from_bytes(data[at + 8:at + 12], "little") != size:
                at = data.find(b"MSCF\0\0\0\0", at + 1)
            if at != -1:
                cab = folder / "attached-container.cab"
                cab.write_bytes(data[at:at + size])
                run(["7z", "x", "-y", "-bso0", "-bsp0", cab, f"-o{folder}"])
                cab.unlink()
    base = folder.resolve()
    for p in root.iter():
        if p.tag.endswith("Payload") and p.get("SourcePath") and p.get("FilePath"):
            # Names come from the download: both ends must stay inside the folder.
            src = (folder / p.get("SourcePath").replace("\\", "/")).resolve()
            dst = (folder / p.get("FilePath").replace("\\", "/")).resolve()
            if base in src.parents and base in dst.parents and src.is_file():
                dst.parent.mkdir(parents=True, exist_ok=True)
                src.rename(dst)


def unpack(path, out, depth=0, log=None):
    """Recursively unpack containers. Returns True if `path` was a container."""
    path, out = pathlib.Path(path), pathlib.Path(out)
    with open(path, "rb") as f:
        head = f.read(8)
    unpacked = False
    if head == OLE_MAGIC and path.suffix.lower() in (".msi", ""):
        unpacked = extract_msi(path, out)
    if not unpacked:
        types = sevenzip_types(path)
        is_exe = path.suffix.lower() == ".exe"
        if is_exe and b"ISSetupStream\0" in path.read_bytes():
            unpacked = unpack_issetupstream(path, out)  # InstallShield Setup Launcher
        if unpacked:
            pass
        elif "compound" in types and is_exe:
            unpacked = carve_embedded_msi(path, out)  # InstallShield: keep real file names
        elif any(t in ARCHIVE_TYPES for t in types):
            out.mkdir(parents=True, exist_ok=True)
            # 7-Zip exits 1 for warnings, 2 and above for errors (corrupt data,
            # disk full): fail rather than cache a partial extraction.
            r = subprocess.run(["7z", "x", "-y", "-p-", "-bso0", "-bsp0", str(path), f"-o{out}"],
                               capture_output=True, text=True, errors="replace")
            if r.returncode > 1:
                raise SystemExit(f"7z failed (exit {r.returncode}) on {path}:\n{r.stderr[-1500:]}")
            unpacked = True
            unpack_burn(path, out)
    if not unpacked:
        return False
    if log is not None:
        log.append(f"{'  ' * depth}{path.name}")
    if depth < 6:
        for child in sorted(out.rglob("*")):
            # Files next to an INF belong to that driver package (co-installers,
            # utilities): unpacking would delete them.
            if (child.is_file() and child.suffix.lower() in CANDIDATE_SUFFIXES
                    and child.stat().st_size > 20_000 and not child.name.lower().endswith(".inf")
                    and not any(sib.suffix.lower() == ".inf" for sib in child.parent.iterdir())):
                if unpack(child, child.parent / (child.name + ".x"), depth + 1, log):
                    child.unlink()
    return True


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def sha256sum(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, sha256, cache):
    cache.mkdir(parents=True, exist_ok=True)
    dest = cache / f"{sha256[:12]}-{url.rsplit('/', 1)[-1]}"
    if dest.exists() and sha256sum(dest) == sha256:
        return dest
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    actual = sha256sum(tmp)
    if actual != sha256:
        tmp.unlink()
        raise SystemExit(f"SHA-256 mismatch for {url}\n  expected {sha256}\n  got      {actual}")
    tmp.rename(dest)
    return dest


def select_driver_dirs(infos):
    """Directories to copy: those holding an applicable INF, minus nested duplicates."""
    dirs = sorted({pathlib.Path(i["path"]).parent for i in infos if i["applies"]}, key=lambda p: (len(p.parts), str(p)))
    chosen = []
    for d in dirs:
        if not any(d == c or c in d.parents for c in chosen):
            chosen.append(d)
    return chosen


def short_name(rel):
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", "-".join(p.removesuffix(".x") for p in rel.parts[-2:]))
    return name[-40:].lstrip("-_.") or "drv"


BOOT_DIR = "$WinPEDriver$"  # Windows Setup installs drivers from this CD folder as boot drivers


def load_variant(path, _seen=()):
    """Read a variant file and merge the variants it includes.

    Returns the variant table plus flat lists of packages and devices. Each
    package gets a "key": its id, or "<included variant>/<id>" for packages
    from an included variant, which is also its directory under the output.
    """
    path = pathlib.Path(path).resolve()
    if path in _seen:
        raise SystemExit(f"variant include loop: {' -> '.join(p.name for p in (*_seen, path))}")
    data = tomllib.loads(path.read_text())
    name = data["variant"]["name"]
    if name != path.stem:
        raise SystemExit(f"[variant] name {name!r} must match the file name {path.name!r}")
    packages = [dict(pkg, key=pkg["id"]) for pkg in data.get("packages", [])]
    devices = list(data.get("devices", []))
    for inc in data["variant"].get("includes", []):
        sub_variant = load_variant(path.parent / f"{inc}.toml", (*_seen, path))
        packages += [dict(pkg, key=f"{inc}/{pkg['key']}") for pkg in sub_variant["packages"]]
        devices += [dict(dev, name=f"{inc}: {dev['name']}") for dev in sub_variant["devices"]]
    keys = [pkg["key"] for pkg in packages]
    if len(keys) != len(set(keys)):
        raise SystemExit(f"{path.name}: duplicate package ids: {sorted({k for k in keys if keys.count(k) > 1})}")
    return {"variant": data["variant"], "packages": packages, "devices": devices}


def cmd_fetch(args):
    variant = load_variant(args.variant)
    name = variant["variant"]["name"]
    out = pathlib.Path(args.output or REPO / "drivers" / name)
    cache = pathlib.Path(args.cache or REPO / ".cache" / "drivers")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    report = [f"# Drivers for {name}", "", variant["variant"].get("description", ""), "",
              f"Checked against Windows 11 build {TARGET_BUILD}, x64, client.", ""]
    manifest, failures = [], []
    staged = {}  # (package sha256, INF path in package) -> package key
    for pkg in variant["packages"]:
        pid = pkg["key"]
        # Boot-critical drivers (storage controllers the node may boot from
        # with no inbox driver) go where Windows Setup installs them as boot
        # drivers; everything else is staged after installation.
        base = out / BOOT_DIR if pkg.get("boot_critical") else out
        print(f"==> {pid}: {pkg['url'].rsplit('/', 1)[-1]}", flush=True)
        src = download(pkg["url"], pkg["sha256"].lower(), cache / "downloads")
        work = cache / "extract" / f"{pkg['sha256'][:16]}-v{UNPACK_VERSION}"
        if not (work / ".done").exists():
            shutil.rmtree(work, ignore_errors=True)
            if not unpack(src, work / "root"):
                raise SystemExit(f"{pid}: could not unpack {src.name}")
            (work / ".done").touch()
        root = work / "root"
        infs = sorted(p for p in root.rglob("*") if p.is_file() and p.suffix.lower() == ".inf")
        inc, exc = pkg.get("include", ["**"]), pkg.get("exclude", [])
        infs = [p for p in infs if any(fnmatch.fnmatch(str(p.relative_to(root)), g) for g in inc)
                and not any(fnmatch.fnmatch(str(p.relative_to(root)), g) for g in exc)]
        infos = [analyse_inf(p) for p in infs]
        # Included variants can share a package: stage each INF once.
        for i in infos:
            first = staged.get((pkg["sha256"], i["path"]))
            if i["applies"] and first:
                i.update(applies=False, reason=f"already staged by {first}")
            elif i["applies"]:
                staged[(pkg["sha256"], i["path"])] = pid
        applicable = [i for i in infos if i["applies"]]
        keep = {pathlib.Path(i["path"]) for i in applicable}
        for i, d in enumerate(select_driver_dirs(infos)):
            dest = base / pid / f"{i:02d}-{short_name(d.relative_to(root))}"
            shutil.copytree(d, dest)
            # Drop INFs Windows 11 would reject or the variant didn't include,
            # so only intended drivers are staged and the build log stays clean.
            for p in dest.rglob("*"):
                if p.suffix.lower() == ".inf" and d / p.relative_to(dest) not in keep:
                    p.unlink()
        hwids = sorted({h for i in applicable for h in i["hardware_ids"]})
        report += [f"## {pid}" + (" (boot-critical)" if pkg.get("boot_critical") else ""), "",
                   pkg.get("description", ""), "",
                   f"Source: {pkg['url']}", "",
                   f"{len(applicable)} of {len(infos)} INFs apply to Windows 11; {len(hwids)} hardware IDs.", ""]
        for i in sorted(infos, key=lambda i: i["path"]):
            rel = pathlib.Path(i["path"]).relative_to(root)
            state = f"yes ({i['decoration']})" if i["applies"] else f"no: {i['reason']}"
            report.append(f"* `{rel}` [{i['class']}, {i['driver_ver']}]: {state}")
        report.append("")
        manifest.append({"id": pid, "url": pkg["url"], "sha256": pkg["sha256"],
                         "boot_critical": bool(pkg.get("boot_critical")),
                         "infs": [{**i, "path": str(pathlib.Path(i["path"]).relative_to(root))} for i in infos]})
        print(f"    {len(applicable)}/{len(infos)} INFs apply to Windows 11, {len(hwids)} hardware IDs")
        if pkg.get("required", True) and not any(i["applies"] or i["reason"].startswith("already staged") for i in infos):
            failures.append(f"no Windows 11 driver in required package {pid}")
    # The build CD uses Joliet names, limited to 64 characters per path component.
    too_long = [str(p.relative_to(out)) for p in out.rglob("*") if len(p.name) > 64]
    if too_long:
        failures.append("path components over 64 characters (Joliet limit): " + ", ".join(too_long[:5]))
    (out / "REPORT.md").write_text("\n".join(report) + "\n")
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    size = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    print(f"\nWrote {out} ({size / 1e6:.0f} MB); see {out / 'REPORT.md'}")
    if failures:
        raise SystemExit("fetch failed:\n  " + "\n  ".join(failures))


def cmd_check_infs(args):
    rc = 0
    for p in sorted(pathlib.Path(args.dir).rglob("*")):
        if p.is_file() and p.suffix.lower() == ".inf":
            i = analyse_inf(p)
            state = f"OK   {i['decoration']}, {len(i['hardware_ids'])} IDs" if i["applies"] else f"SKIP {i['reason']}"
            print(f"{state:45} {p.relative_to(args.dir)}")
    return rc


def cmd_dell_catalog(args):
    """Suggest the newest Windows driver package per family for a Dell system ID."""
    cache = pathlib.Path(args.cache or REPO / ".cache" / "drivers")
    cat = download_catalog(cache)
    root = ET.fromstring(gzip.decompress(cat.read_bytes()).decode("utf-16"))
    oses = set(args.os.split(","))
    families = {}
    for sc in root.iter("SoftwareComponent"):
        ctype = sc.find("ComponentType")
        if ctype is None or ctype.get("value") != "DRVR" or sc.get("packageType") not in ("LWXP", "LW64"):
            continue
        if args.system_id not in {m.get("systemID") for m in sc.iter("Model")}:
            continue
        if not oses & {o.get("osCode") for o in sc.iter("OperatingSystem")}:
            continue
        name = sc.find("Name/Display").text.strip()
        category = sc.find("Category/Display").text.strip()
        # Package names differ between releases only in version numbers and
        # filler words, so drop those to group releases of the same driver.
        stem = re.sub(r"\b(version|update|for|the|drivers?|ws?\d+)\b|[\d.,()-]+", " ", name.lower())
        family = (category, " ".join(stem.split()))
        date = sc.get("dateTime", "")
        if family not in families or date > families[family].get("dateTime", ""):
            families[family] = sc
    for (category, _), sc in sorted(families.items(), key=lambda kv: kv[0]):
        sha = sc.get("hash") if (sc.get("hashAlgorithm") or "").upper() == "SHA256" else ""
        print(f'[[packages]]\nid = "{sc.get("releaseID").lower()}"\n'
              f'description = "{category}: {sc.find("Name/Display").text.strip()} ({sc.get("vendorVersion")})"\n'
              f'url = "https://downloads.dell.com/{sc.get("path")}"\nsha256 = "{sha}"\n')


def inbox_infs(source, cache):
    """Windows' own INFs, from a directory (e.g. a mounted C:\\Windows\\INF) or
    from install.wim / install.esd via 7-Zip."""
    source = pathlib.Path(source)
    if source.is_dir():
        return source
    st = source.stat()  # mount points get reused for different ISOs: key on the WIM itself
    out = cache / "inbox" / hashlib.sha256(f"{source.resolve()}|{st.st_size}|{st.st_mtime_ns}".encode()).hexdigest()[:16]
    if not (out / ".done").exists():
        shutil.rmtree(out, ignore_errors=True)
        out.mkdir(parents=True)
        # Inbox drivers live in the DriverStore (Windows/INF only has some).
        # Single-image WIMs list paths from the root, multi-image ones under 1/, 2/, ...
        for prefix in ("", "1/"):
            for pattern in ("Windows/INF/*.inf", "Windows/System32/DriverStore/FileRepository/*/*.inf"):
                run(["7z", "x", "-y", "-bso0", "-bsp0", source, f"-o{out}", prefix + pattern])
        if not any(out.rglob("*.inf")):
            raise SystemExit(f"no Windows/INF/*.inf found in {source}")
        (out / ".done").touch()
    return out


def hwid_index(root, inbox):
    index = {}
    for p in pathlib.Path(root).rglob("*"):
        if p.is_file() and p.suffix.lower() == ".inf":
            i = analyse_inf(p, inbox=inbox)
            if i["applies"]:
                # Staged: the package key, i.e. the path up to the "NN-" driver folder.
                parts = p.relative_to(root).parts
                label = p.name if inbox else "/".join(
                    x for x in parts[:next((n for n, x in enumerate(parts) if re.match(r"\d\d-", x)), 1)]
                    if x != BOOT_DIR)
                for h in i["hardware_ids"]:
                    index.setdefault(h, set()).add(label)
    return index


def matches(index, pattern):
    """pattern is a PCI ID prefix such as PCI\\VEN_15B3&DEV_1017 or a class code PCI\\CC_010802."""
    pattern = pattern.upper()
    return sorted({v for h, vs in index.items() if h.startswith(pattern) for v in vs})


def cmd_coverage(args):
    variant = load_variant(args.variant)
    name = variant["variant"]["name"]
    cache = pathlib.Path(args.cache or REPO / ".cache" / "drivers")
    staged_dir = pathlib.Path(args.drivers or REPO / "drivers" / name)
    if not staged_dir.is_dir():
        raise SystemExit(f"{staged_dir} not found: run 'drivers.py fetch {args.variant}' first")
    inbox = hwid_index(inbox_infs(args.inbox, cache), inbox=True)
    staged = hwid_index(staged_dir, inbox=False)
    missing = []
    width = max([len(d["name"]) for d in variant["devices"]] + [6])
    print(f"{'Device':{width}} {'Windows 11 inbox':28} Staged by this variant")
    for dev in variant["devices"]:
        ib = sorted({x for pat in dev["ids"] for x in matches(inbox, pat)})
        st = sorted({x for pat in dev["ids"] for x in matches(staged, pat)})
        flag = "" if (ib or st) else ("  <-- NOT COVERED" if dev.get("required", True) else "  (not covered, optional)")
        print(f"{dev['name']:{width}} {', '.join(ib)[:28] or '-':28} {', '.join(st) or '-'}{flag}")
        if not (ib or st) and dev.get("required", True):
            missing.append(dev["name"])
    if missing:
        raise SystemExit("\nNo Windows 11 driver for: " + ", ".join(missing))


def download_catalog(cache):
    """Dell's catalog changes often and is not pinned: it is only used for suggestions."""
    cache.mkdir(parents=True, exist_ok=True)
    dest = cache / "Catalog.xml.gz"
    req = urllib.request.Request("https://downloads.dell.com/catalog/Catalog.xml.gz", headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)
    return dest


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch", help="download, unpack and check a variant's drivers")
    f.add_argument("variant")
    f.add_argument("--output", help="default: drivers/<variant name>")
    f.add_argument("--cache", help="default: .cache/drivers")
    c = sub.add_parser("check-infs", help="report which INFs under DIR Windows 11 x64 accepts")
    c.add_argument("dir")
    v = sub.add_parser("coverage", help="check every device in a variant has a Windows 11 driver")
    v.add_argument("variant")
    v.add_argument("--inbox", required=True,
                   help="Windows' INFs: install.wim/install.esd from the ISO, or a directory of INFs")
    v.add_argument("--drivers", help="default: drivers/<variant name>")
    v.add_argument("--cache")
    d = sub.add_parser("dell-catalog", help="suggest Dell driver packages for a system ID")
    d.add_argument("--system-id", required=True, help="e.g. 0737 for PowerEdge R740xd (the SKU in Ironic inventory)")
    d.add_argument("--os", default="W22SE,W25SE", help="Dell OS codes to accept (default: Server 2022/2025)")
    d.add_argument("--cache")
    args = ap.parse_args()
    return {"fetch": cmd_fetch, "check-infs": cmd_check_infs, "coverage": cmd_coverage,
            "dell-catalog": cmd_dell_catalog}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
