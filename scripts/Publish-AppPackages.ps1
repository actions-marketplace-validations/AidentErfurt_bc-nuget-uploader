<#
 .SYNOPSIS
     Builds each *.app once and then pushes the resulting .nupkg
     to all feeds resolved from nuget-feed-map.json (or default GitHub feed).

 .NOTES
     Requires BcContainerHelper (pulled in via AL-Go helper).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function DownloadHelperFile {
    param([string]$url, [string]$folder)
    $ProgressPreference, $prev = 'SilentlyContinue', $ProgressPreference
    try {
        $name = Split-Path $url -Leaf
        $path = Join-Path $folder $name
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
        return $path
    } finally { $ProgressPreference = $prev }
}

function Write-SummaryLine {
    param([string]$text)

    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $text
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null

. (DownloadHelperFile -url 'https://raw.githubusercontent.com/microsoft/AL-Go-Actions/v7.2/AL-Go-Helper.ps1' -folder $tmp) -local
DownloadAndImportBcContainerHelper

# read configuration
$workspace = $env:GITHUB_WORKSPACE
$feedMapPath = $env:FEED_MAP_PATH
if (-not [IO.Path]::IsPathRooted($feedMapPath)) {
    $feedMapPath = Join-Path $workspace $feedMapPath
}

$feedMap = @{}
if (Test-Path $feedMapPath) {
    Write-Host "Using feed map: $feedMapPath"
    $feedMap = Get-Content $feedMapPath | ConvertFrom-Json
} else {
    Write-Host "No feed-map found -> all packages go to GitHub Packages"
}

$defaultFeed = "https://nuget.pkg.github.com/$env:GITHUB_REPOSITORY_OWNER/index.json"

# discover .app files
$appFiles = Get-ChildItem -Path "$workspace/upload" -Filter '*.app' -File
if (-not $appFiles) {
    Write-Host "No .app files to process. Exiting."
    exit 0
}

# summary scaffolding
"" | Set-Content $env:GITHUB_STEP_SUMMARY
Write-SummaryLine "| Package | Version | Feed | Result |"
Write-SummaryLine "|---------|---------|------|--------|"
$overallFailure = $false

foreach ($app in $appFiles) {
    Write-Host " Processing $($app.Name)"
    $nupkg = New-BcNuGetPackage -appfile $app.FullName
    Write-Host " Built: $nupkg"

    $meta       = Get-AppJsonFromAppFile -appFile $app.FullName
    $guid       = $meta.id
    $pkgId      = Get-BcNuGetPackageId -publisher $meta.publisher -name $meta.name -id $meta.id
    $pkgVersion = $meta.version

    # Resolve all feeds needed for this GUID
    $destinations = @()

    # accepts either {url,token} or an array of them
    if ($feedMap.PSObject.Properties.Name -contains $guid) {
        $entries = $feedMap.$guid
        if ($entries -is [System.Collections.IEnumerable]) { $entries } else { ,$entries } |
            ForEach-Object {
                $destinations += [pscustomobject]@{
                    Url       = $_.url
                    TokenName = $_.token
                }
            }
    } else {
        $destinations += [pscustomobject]@{
            Url       = $defaultFeed
            TokenName = 'GITHUB_TOKEN'
        }
    }

    # Deduplicate (in case two GUIDs share same feed+token)
    $destinations = $destinations |
        Sort-Object Url,TokenName -Unique

    foreach ($dest in $destinations) {
        $token = [Environment]::GetEnvironmentVariable($dest.TokenName)
        if (-not $token) {
            $msg = "Secret `${dest.TokenName} not set"
            Write-Host $msg
            Write-SummaryLine "| $pkgId | $pkgVersion | $($dest.Url) | secret missing |"
            $overallFailure = $true
            continue
        }

        try {
            # Skip if already there
            $exists = Get-BcNuGetPackage `
                        -nuGetServerUrl $dest.Url `
                        -nuGetToken      $token `
                        -packageName     $pkgId `
                        -version         $pkgVersion `
                        -select 'Exact'  `
                        -allowPrerelease

            if ($exists) {
                Write-Host "$pkgId $pkgVersion already exists on $($dest.Url)"
                Write-SummaryLine "| $pkgId | $pkgVersion | $($dest.Url) | already exists |"
                continue
            }
        } catch {
            Write-Host "Could not query $($dest.Url) (continuing): $($_.Exception.Message)"
        }

        try {
            Write-Host "Pushing to $($dest.Url)"
            Push-BcNuGetPackage -bcNuGetPackage $nupkg -nuGetServerUrl $dest.Url -nuGetToken $token
            Write-SummaryLine "| $pkgId | $pkgVersion | $($dest.Url) | uploaded |"
        } catch {
            Write-Host "Push failed: $($_.Exception.Message)"
            Write-SummaryLine "| $pkgId | $pkgVersion | $($dest.Url) | failed |"
            $overallFailure = $true
        }
    }
}

# final outcome
if (($env:FAIL_ON_ANY_ERROR -eq 'true') -and $overallFailure) {
    throw "One or more uploads failed and fail-on-any-error=true"
}
