# Extract the shipping update function; no network requests or live-server changes.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$projectRoot = Split-Path $PSScriptRoot -Parent
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'server.ps1'), [ref]$null, [ref]$null)
$fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-UpdateInfo' }, $true)
if (-not $fn) { throw 'Missing Get-UpdateInfo function' }
. ([scriptblock]::Create($fn.Extent.Text))
$script:Config = [pscustomobject]@{ '当前版本' = 'v20260922'; 'GitHub仓库' = 'Bigesila-B/MiniMax-H3-Workstation-UI'; '分支' = 'main' }
$script:ReleaseAvailable = $true
$script:LatestTag = 'v20261012'
$script:Sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
function Get-UpdateConfigData { return $script:Config }
function Invoke-UpdateRequest {
    param($Url, $Accept, $Timeout)
    $status = [System.Net.HttpStatusCode]::OK
    if ($Url.EndsWith('/releases/latest')) {
        if (-not $script:ReleaseAvailable) { $status = [System.Net.HttpStatusCode]::NotFound }
        $data = @{ tag_name = $script:LatestTag; name = 'Fixture release'; html_url = 'https://github.com/fixture'; published_at = '2026-10-12T00:00:00Z' }
    } else {
        $data = @{ sha = $script:Sha; commit = @{ message = 'Fixture commit'; committer = @{ date = '2026-10-12T00:00:00Z' } } }
    }
    $response = New-Object System.Net.Http.HttpResponseMessage -ArgumentList $status
    $response.Content = New-Object System.Net.Http.StringContent -ArgumentList ($data | ConvertTo-Json -Depth 5)
    return $response
}
function Assert-Check($Name, $Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Output "PASS: $Name"
}
$result = Get-UpdateInfo $true
Assert-Check 'Older release detects new version and keeps current tag' ($result.hasUpdate -and $result.currentVersion -eq 'v20260922' -and $result.latestVersion -eq 'v20261012' -and -not $result.unversioned)
$script:Config.'当前版本' = 'v20261012'
$result = Get-UpdateInfo $true
Assert-Check 'Installed release is current' (-not $result.hasUpdate -and $result.currentVersion -eq 'v20261012' -and $result.channel -eq 'release')
$script:Config.'当前版本' = ''
$result = Get-UpdateInfo $true
Assert-Check 'Missing version is reported explicitly' ($result.unversioned -and -not $result.hasUpdate)
$script:ReleaseAvailable = $false
$script:Config.'当前版本' = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$result = Get-UpdateInfo $true
Assert-Check 'Release unavailable falls back to commits' ($result.channel -eq 'commit' -and $result.hasUpdate -and $result.currentVersion -eq $script:Config.'当前版本')
$script:Config.'当前版本' = $script:Sha
$result = Get-UpdateInfo $true
Assert-Check 'Matching commit is current' (-not $result.hasUpdate -and -not $result.unversioned)
Assert-Check 'Cache preserves current version' ((Get-UpdateInfo).currentVersion -eq $script:Sha)
