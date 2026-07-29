$ErrorActionPreference = "Stop"
$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$arch = switch ($osArchitecture) {
    "X64" { "amd64"; break }
    "Arm64" { "arm64"; break }
    default { throw "E_ARCH_UNSUPPORTED: $osArchitecture" }
}
$binary = Join-Path $pluginRoot "bin/routerctl-windows-$arch.exe"
if (-not (Test-Path -LiteralPath $binary)) {
  throw "E_BINARY_MISSING: this plugin release lacks routerctl-windows-$arch.exe"
}
& $binary --source $pluginRoot @args
exit $LASTEXITCODE
