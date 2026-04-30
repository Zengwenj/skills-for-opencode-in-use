@echo off
chcp 65001 > nul
REM Obsidian 统一搜索 - Windows 批处理版本
REM 调用 PowerShell 脚本

powershell.exe -ExecutionPolicy Bypass -File "%~dp0smart-search.ps1" -Query %*