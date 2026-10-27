@echo off
REM Lanza el configurador sin administrador.
REM Uso: Ejecutar_setup.cmd [-DryRun ^| -TestMode] [-Squad SG_3]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_modelado.ps1" %*
