Hand-extracted drivers for builds that don't use a hardware variant. For
known hardware, prefer a variant (`variants/*.toml`, built with
`scripts/build-variant.sh`), which fetches, checks and stages drivers for you.

Put one directory per driver here, each containing its `.inf`, `.sys` and
`.cat` files. Everything here is put on the build CD and every `.inf` found is
added to the Windows driver store. Check that Windows 11 accepts them with:

    .venv/bin/python scripts/drivers.py check-infs drivers/vendor-drivers

The CD is written with Joliet names, which are limited to 64 characters per
name and 120 per path from the CD root, so keep names short.
