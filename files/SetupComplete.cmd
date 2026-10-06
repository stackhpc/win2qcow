@echo off
rem Run by Windows Setup once, after OOBE, on the deployed node.
powershell -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\post-deploy.ps1"
del /q "%WINDIR%\Setup\Scripts\post-deploy.ps1"
