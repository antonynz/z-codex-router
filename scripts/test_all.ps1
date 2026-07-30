$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, ".."))
$Engine = (Get-Process -Id $PID).Path

foreach ($relative in @(
    "install.ps1",
    "plugins/z-codex-router/scripts/routerctl.ps1",
    "scripts/test_routerctl.ps1",
    "scripts/test_install.ps1",
    "scripts/test_policy.ps1",
    "scripts/verify_source.ps1",
    "scripts/package_release.ps1",
    "scripts/test_release.ps1"
)) {
    $path = [IO.Path]::Combine($Root, $relative.Replace([char]'/', [IO.Path]::DirectorySeparatorChar))
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $firstError = $errors[0]
        $errorLine = $firstError.Extent.StartLineNumber
        $errorColumn = $firstError.Extent.StartColumnNumber
        $errorText = $firstError.Extent.Text.Replace("`r", "\r").Replace("`n", "\n")
        throw "PowerShell parse failed: $relative`: line=$errorLine column=$errorColumn near=$errorText message=$($firstError.Message)"
    }
}

foreach ($scriptName in @(
    "test_routerctl.ps1",
    "test_install.ps1",
    "test_policy.ps1",
    "verify_source.ps1",
    "test_release.ps1"
)) {
    & $Engine -NoProfile -ExecutionPolicy Bypass -File ([IO.Path]::Combine($PSScriptRoot, $scriptName))
    if ($LASTEXITCODE -ne 0) { throw "$scriptName failed with $LASTEXITCODE" }
}
