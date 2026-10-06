Put extracted vendor drivers for the Ironic nodes here (NIC, storage/RAID
controller, chipset), one directory per driver, each containing its `.inf`,
`.sys` and `.cat` files. Everything here is put on the build CD and every
`.inf` found is added to the Windows driver store.

The CD is written with Joliet names, which are limited to 64 characters per
path component, so keep file and directory names short.
