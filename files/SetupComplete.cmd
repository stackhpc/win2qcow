@echo off
rem Run by Windows Setup once, after OOBE, on the deployed node.
rem cloudbase-init stays on Manual until now so the service cannot run
rem alongside the specialize-pass cloudbase-init (same as the upstream MSI).
sc config cloudbase-init start= auto
net start cloudbase-init
