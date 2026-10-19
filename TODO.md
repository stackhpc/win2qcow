# TODO

## Replace Dell-hosted drivers in the HPE variant

`variants/hpe-proliant-dl360-gen10.toml` takes two packages from Dell's
download site because HPE's are missing or can't be unpacked:

| Package | Dell package | Why not HPE's |
|---|---|---|
| `intel-x520-x540` (Intel 82599/X540, ixn/ixt) | X9PPT 22.0.0 | HPE's current `ixs` component dropped these chips |
| `emulex-fc` (Emulex LPe31000/LPe35000) | 8XGGG 12.34.10 | HPE's cp070317 wraps the driver in a Tarma installer that `drivers.py` can't unpack |

Dell's [EULA](https://www.dell.com/aeula) (section 2.1(A)) says to run the
software "only on the hardware for which it was intended to operate". Neither
package gives separate rights: the Emulex package has no Broadcom licence,
and the Intel package's licence is an OEM agreement that only takes effect
under a non-disclosure agreement with Intel. Using them on HPE servers may
fall outside Dell's terms (see "Licensing and redistribution" in the README).

To do:

1. Find the same drivers on Intel's and Broadcom's own download sites (Intel
   PROSet / Ethernet Adapter Complete Driver Pack with X520/X540 support;
   Broadcom's Emulex LPe31000/35000 Windows driver kit), and check their
   licences allow use on any server.
2. Pin them by URL and SHA-256 in the HPE variant, with `include` patterns
   for the Windows Server 2022/2025 INFs, and run `drivers.py fetch` and
   `coverage` for `hpe-proliant-dl360-gen10` and `dell-hpe-servers`.
3. Consider using the same sources in `dell-poweredge-r740xd.toml`, so both
   servers share one package and the combined image stages it once.
4. Rebuild `dell-hpe-servers` and repeat the deploy tests.

Until then, don't deploy the HPE variant (or the combined image) to HPE
nodes with Intel 82599/X540 or Emulex FC adapters without confirming the
terms with Dell.
