@echo off
set "BT_RECOVERY_APP=%~dp0app.ps1"
powershell.exe -NoProfile -Command "try { Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File '+[char]34+$env:BT_RECOVERY_APP+[char]34) -ErrorAction Stop } catch { Write-Host $_.Exception.Message; Read-Host 'Press Enter' }"
