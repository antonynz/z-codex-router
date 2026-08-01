$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Engine = (Get-Process -Id $PID).Path
& $Engine -NoProfile -ExecutionPolicy Bypass -File ([IO.Path]::Combine($PSScriptRoot, "test_install.ps1"))
exit $LASTEXITCODE
