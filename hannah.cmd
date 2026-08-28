@echo off
rem Hannah: the `hannah` command on Windows: runs hannah.ps1 next to this file (no admin, user session only).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hannah.ps1" %*
