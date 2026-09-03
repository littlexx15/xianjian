@echo off
chcp 65001 >nul
title 鲜剪
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0水果混剪器.ps1"
if errorlevel 1 pause
