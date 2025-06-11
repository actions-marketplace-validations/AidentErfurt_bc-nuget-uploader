function DownloadHelperFile {
    param(
        [string] $url,
        [string] $folder
    )
    try {
        $prevProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        $name = [System.IO.Path]::GetFileName($url)
        Write-Host "Downloading $name from $url"
        $path = Join-Path $folder $name
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $path
        return $path
    }
    catch {
        Write-Error "Failed to download file from $url. $_"
        exit 1
    }
    finally {
        $ProgressPreference = $prevProgressPreference
    }
}

# Create a temporary folder for helper files
$tmpFolder = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
New-Item -Path $tmpFolder -ItemType Directory -Force | Out-Null

# Download and import the AL-Go helper script
$ALGoHelperPath = DownloadHelperFile -url 'https://raw.githubusercontent.com/microsoft/AL-Go-Actions/v7.2/AL-Go-Helper.ps1' -folder $tmpFolder
. $ALGoHelperPath -local
DownloadAndImportBcContainerHelper

# Load feed map from env var
$rawFeedMapPath = [Environment]::GetEnvironmentVariable("FEED_MAP_PATH")
$workspaceRoot  = [Environment]::GetEnvironmentVariable("GITHUB_WORKSPACE")

# Resolve path relative to workspace, if needed
if (-not [System.IO.Path]::IsPathRooted($rawFeedMapPath)) {
    $feedMapPath = Join-Path -Path $workspaceRoot -ChildPath $rawFeedMapPath
} else {
    $feedMapPath = $rawFeedMapPath
}

$feeds = @{}
if (Test-Path $feedMapPath) {
    Write-Host "ℹ️ Using feed map from $feedMapPath"
    $feeds = Get-Content $feedMapPath | ConvertFrom-Json
    Write-Host "✅ Loaded feed map with $($feeds.Count) entries"
} else {
    Write-Host "⚠️ Feed map file not found at $feedMapPath — using default GitHub feed"
}

# Find app files
$appFiles = @(Get-ChildItem -Path "./upload" -Filter "*.app")
if ($appFiles.Count -eq 0) {
    Write-Host "No .app files found in ./upload folder."
    exit 0
}

# Process each .app file
foreach ($file in $appFiles) {
    $appfile = $file.FullName
    Write-Host "🔄 Processing file: $appfile"
    $nupkg = New-BcNuGetPackage -appfile $appfile
    Write-Host "📦 Created package: $nupkg"

    # Get metadata
    $appJson = Get-AppJsonFromAppFile -appFile $appfile
    $packageId = Get-BcNuGetPackageId -publisher $appJson.publisher -name $appJson.name -id $appJson.id
    $packageVersion = $appJson.version
    $guid = $appJson.id

    # Default values
    $targetFeed = "https://nuget.pkg.github.com/$env:GITHUB_REPOSITORY_OWNER/index.json"
    $tokenName  = "GITHUB_TOKEN"

    # Check if override exists for this app ID
    if ($feeds.PSObject.Properties.Name -contains $guid) {
        $targetFeed = $feeds.$guid.url
        $tokenName  = $feeds.$guid.token
    }

    # Show resolved info
    Write-Host "📦 Package GUID: $guid"
    Write-Host "🔐 Using token environment variable: $tokenName"
    Write-Host "🌍 Upload target feed: $targetFeed"

    # Get the actual token value
    $token = [Environment]::GetEnvironmentVariable($tokenName)
    if (-not $token) {
        Write-Host "❌ Token for GUID $guid (`$tokenName = $tokenName) is missing."
        Write-Host "Available environment variables:"
        Get-ChildItem Env:
        throw "Token for GUID $guid (`$tokenName) is missing."
    } else {
        Write-Host "🔐 Token found: $tokenName"
        # Write-Host "🔑 Token length: $($token.Length)"
    }

    # Check if package already exists
    try {
        $existing = Get-BcNuGetPackage `
            -nuGetServerUrl $targetFeed `
            -nuGetToken $token `
            -packageName $packageId `
            -version $packageVersion `
            -select 'Exact' `
            -allowPrerelease

        if ($existing -and (Test-Path $existing)) {
            Write-Host "⚠️ Package already exists: $packageId $packageVersion — skipping upload"
            continue
        }
    }
    catch {
        Write-Host "❗ Exception while checking for existing package:"
        Write-Host $_.Exception.Message
        Write-Host $_.Exception.ToString()
        Write-Host "ℹ️ Proceeding with upload..."
    }

    # Upload
    Write-Host "⬆️ Pushing package to $targetFeed"
    try {
        Push-BcNuGetPackage -nuGetServerUrl $targetFeed -nuGetToken $token -bcNuGetPackage $nupkg
        Write-Host "✅ Successfully pushed ${nupkg} to ${targetFeed}"
    }
    catch {
        Write-Error "❌ Failed to push ${nupkg} to ${targetFeed}: $_"
        throw $_
    }
}
