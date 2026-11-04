@echo off
rem Windows stand-in for lmutil: see lmutil.ps1.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0lmutil.ps1" %*
