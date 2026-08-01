@echo off
rem Windows-only fixture for Job Object smoke tests.
powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 300') -PassThru; Write-Output ('CHILD_PID=' + $child.Id); Wait-Process -Id $child.Id"
