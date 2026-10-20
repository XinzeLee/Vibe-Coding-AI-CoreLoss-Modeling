[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Preview', 'Full')]
    [string]$Stage = 'Preview',
    [switch]$Promote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Promote -and $Stage -ne 'Full') { throw '-Promote requires -Stage Full.' }

$Workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/')
$PrivateRoot = Join-Path $Workspace '.private-stage2'
$ArchiveRoot = Join-Path $PrivateRoot 'full'
$ManifestPath = Join-Path $PrivateRoot 'manifest.json'
$OutputRoot = Join-Path $Workspace ('dist/' + $Stage.ToLowerInvariant())
$Utf8 = [Text.UTF8Encoding]::new($false)

function Assert-Within([string]$Path, [string]$Root) {
    $absolute = [IO.Path]::GetFullPath($Path)
    $boundary = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must stay inside ${Root}: $Path"
    }
    # A junction could otherwise make a lexically safe path leave the workspace.
    $cursor = $absolute
    while ($cursor -and $cursor.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Release paths must not contain junctions or symbolic links: $cursor"
            }
        }
        if ($cursor -eq $Root) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $absolute
}

function Get-SourcePath([string]$Root, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)' -or $Relative -match ':') {
        throw "Invalid release-relative path: $Relative"
    }
    return Assert-Within (Join-Path $Root $Relative) $Root
}

function Get-RelativeFiles([string]$Root) {
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | ForEach-Object {
        $null = Assert-Within $_.FullName $Root
        [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
    } | Sort-Object)
}

function Assert-Archive {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) {
        throw 'The local Stage 2 archive is missing. A fresh clone can build Preview, but Full requires .private-stage2/full and manifest.json from this computer.'
    }
    $null = Assert-Within $ManifestPath $Workspace
    $null = Assert-Within $ArchiveRoot $Workspace
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($manifest.format -ne 1 -or @($manifest.files).Count -eq 0) { throw 'Unsupported or empty Stage 2 manifest.' }
    $entries = @{}
    foreach ($entry in $manifest.files) {
        $relative = ([string]$entry.path).Replace('\', '/')
        if ($entries.ContainsKey($relative) -or $entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid or duplicate archive entry: $relative" }
        $source = Get-SourcePath $ArchiveRoot $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Archive file missing: $relative" }
        if ((Get-Item -LiteralPath $source).Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "Archive integrity check failed: $relative"
        }
        $entries[$relative] = $entry
    }
    $actual = @(Get-RelativeFiles $ArchiveRoot)
    if ($actual.Count -ne $entries.Count -or @($actual | Where-Object { -not $entries.ContainsKey($_) }).Count -ne 0) {
        throw 'Archive file count/path set does not match its manifest.'
    }
    Write-Host "Verified Stage 2 source snapshot: $($entries.Count) files."
    return $entries
}

function Get-PreviewFiles {
    $files = @(
        'index.html', 'overview.html', 'lab.html', 'quiz.html', 'badge.html', 'sw.js',
        'assets/css/app.css', 'assets/js/preparation.js', 'assets/js/likes.js', 'assets/js/offline.js',
        'assets/img/apec-2027-original.png', 'assets/img/core-loss-preview.webp'
    )
    $referenced = $false
    foreach ($relative in $files | Where-Object { $_ -match '\.(html|css|js)$' -and $_ -ne 'sw.js' }) {
        $path = Get-SourcePath $Workspace $relative
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-Content -LiteralPath $path -Raw) -match 'howto-strip\.webp') { $referenced = $true }
    }
    if ($referenced) { $files += 'assets/img/howto-strip.webp' }
    return @($files | Sort-Object -Unique)
}

function Get-FullFiles {
    $worker = Get-Content -LiteralPath (Join-Path $ArchiveRoot 'sw.js') -Raw
    $match = [regex]::Match($worker, '(?s)const FILES = \[(.*?)\];')
    if (-not $match.Success) { throw 'Cannot read the archived service-worker runtime allowlist.' }
    $files = @('sw.js') + @([regex]::Matches($match.Groups[1].Value, '"([^"\r\n]+)"') | ForEach-Object {
        $relative = $_.Groups[1].Value
        if ($relative -ne './') { $relative }
    })
    return @($files | Sort-Object -Unique)
}

function Get-Worker([string]$Template, [string[]]$Files, [string]$Version) {
    if ($Template -notmatch 'const VERSION = "[^"]+";' -or $Template -notmatch '(?s)const FILES = \[.*?\];') {
        throw 'Unexpected service-worker template.'
    }
    $versioned = [regex]::Replace($Template, 'const VERSION = "[^"]+";', ('const VERSION = "' + $Version + '";'))
    $cached = @('./') + @($Files | Where-Object { $_ -ne 'sw.js' })
    $replacement = "const FILES = [`n" + (($cached | ForEach-Object { '  "' + $_ + '"' }) -join ",`n") + "`n];"
    return [regex]::Replace($versioned, '(?s)const FILES = \[.*?\];', $replacement)
}

function Assert-Package([string]$Root, [string[]]$Files, [string]$PackageStage) {
    $actual = @(Get-RelativeFiles $Root)
    if (@(Compare-Object -ReferenceObject @($Files | Sort-Object) -DifferenceObject $actual).Count -ne 0) {
        throw 'Package file set differs from the release allowlist.'
    }
    foreach ($relative in $actual | Where-Object { $_ -match '\.(html|css|js)$' }) {
        $path = Get-SourcePath $Root $relative
        $body = Get-Content -LiteralPath $path -Raw
        if ($body -match '\.private-stage2|design-demos/|comic/lab-howto|\.baoyu-skills') { throw "Private/authoring reference found in package: $relative" }
        if ($PackageStage -eq 'Preview' -and $body -match 'window\.LAB\s*=|APEC2027_vibe_coding\.ipynb|backupNotebook|assets/js/(?:content|progress|lab|quiz|badge|certificate|prompt-builder|model-diagrams|excellence-progress)\.js|certificate-midnight-background|certificate-learning-emblem|id=["''](?:badge-canvas|download-btn)["'']') {
            throw "Full-workshop content found in Preview package: $relative"
        }
        $references = @()
        if ($relative -match '\.html$') {
            $references += @([regex]::Matches($body, '(?i)\b(?:src|href)\s*=\s*["'']([^"'']+)["'']') | ForEach-Object { $_.Groups[1].Value })
        }
        if ($relative -match '\.css$') {
            $references += @([regex]::Matches($body, '(?i)url\(\s*["'']?([^"'')\s]+)["'']?\s*\)') | ForEach-Object { $_.Groups[1].Value })
        }
        foreach ($reference in $references) {
            if ($reference -match '^(?:[a-z][a-z0-9+.-]*:|//|#)') { continue }
            $clean = ($reference -split '[?#]', 2)[0]
            if (-not $clean -or $clean -eq './') { continue }
            $target = if ($clean.StartsWith('/')) { Join-Path $Root $clean.TrimStart('/') } else { Join-Path ([IO.Path]::GetDirectoryName($path)) $clean }
            $target = Assert-Within $target $Root
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Missing local package reference in ${relative}: $reference" }
        }
    }
    Write-Output "Validated $PackageStage publication package: $($actual.Count) allowlisted files."
}

function Save-Preview([string[]]$Files) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff')
    $snapshot = Assert-Within (Join-Path $PrivateRoot ('previews/' + $stamp)) $Workspace
    $null = New-Item -ItemType Directory -Path $snapshot -Force
    $entries = @()
    foreach ($relative in @($Files + 'README.md' | Sort-Object -Unique)) {
        $source = Get-SourcePath $Workspace $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Current preview file missing before promotion: $relative" }
        $target = Get-SourcePath $snapshot $relative
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
        Copy-Item -LiteralPath $source -Destination $target
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $hash) { throw "Preview backup verification failed: $relative" }
        $entries += [ordered]@{ path = $relative; sha256 = $hash; bytes = (Get-Item -LiteralPath $target).Length }
    }
    $snapshotManifest = [ordered]@{ format = 1; createdUtc = [DateTime]::UtcNow.ToString('o'); description = 'Current preview before manual Stage 2 promotion'; files = $entries }
    [IO.File]::WriteAllText((Join-Path $snapshot 'manifest.json'), ($snapshotManifest | ConvertTo-Json -Depth 6), $Utf8)
    Write-Output "Saved and hash-verified private preview backup: $snapshot"
}

$archiveEntries = $null
if ($Stage -eq 'Full') { $archiveEntries = Assert-Archive }
$SourceRoot = if ($Stage -eq 'Full') { $ArchiveRoot } else { $Workspace }
$Files = if ($Stage -eq 'Full') { @(Get-FullFiles) } else { @(Get-PreviewFiles) }
if ($Promote) {
    $previewFiles = @(Get-PreviewFiles)
    $existingFullFiles = @($Files | Where-Object {
        $_ -notin $previewFiles -and (Test-Path -LiteralPath (Get-SourcePath $Workspace $_) -PathType Leaf)
    })
    $hasFullMarkup = $false
    foreach ($page in @('index.html', 'overview.html', 'lab.html', 'quiz.html', 'badge.html')) {
        $pagePath = Get-SourcePath $Workspace $page
        if ((Test-Path -LiteralPath $pagePath -PathType Leaf) -and (Get-Content -LiteralPath $pagePath -Raw) -match 'assets/js/(?:content|progress|lab|quiz|badge|certificate|prompt-builder|model-diagrams|excellence-progress)\.js') {
            $hasFullMarkup = $true
        }
    }
    if ($existingFullFiles.Count -ne 0 -or $hasFullMarkup) {
        throw 'Promotion is a one-time Preview-to-Full transition. Full workshop source is already present at the repository root; refusing before writing any output to protect local Full edits. Build with -Stage Full without -Promote instead.'
    }
}
foreach ($relative in $Files) {
    $source = Get-SourcePath $SourceRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Release source file missing: $relative" }
    if ($Stage -eq 'Full' -and -not $archiveEntries.ContainsKey($relative)) { throw "Runtime file absent from archive manifest: $relative" }
}
$null = Assert-Within $OutputRoot $Workspace
$offline = Get-Content -LiteralPath (Join-Path $Workspace 'assets/js/offline.js') -Raw
if ($offline -notmatch 'hadController' -or $offline -notmatch 'location\.reload\(\)') { throw 'Current offline.js must include the guarded stage-transition reload.' }
$version = 'workshop-' + $(if ($Stage -eq 'Preview') { 'stage1' } else { 'stage2' }) + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff')
# The current worker provides compatible transition handling for both stages;
# only the Full file allowlist comes from the verified private worker.
$worker = Get-Worker (Get-Content -LiteralPath (Join-Path $Workspace 'sw.js') -Raw) $Files $version
$action = if ($Promote) { 'Build Full, save a private preview backup, and manually restore full runtime files at the repository root' } else { "Build and validate $Stage from its explicit allowlist" }
if (-not $PSCmdlet.ShouldProcess($OutputRoot, $action)) { return }

if (Test-Path -LiteralPath $OutputRoot) {
    $null = Assert-Within $OutputRoot (Join-Path $Workspace 'dist')
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $OutputRoot -Force
foreach ($relative in $Files) {
    $source = Get-SourcePath $SourceRoot $relative
    $target = Get-SourcePath $OutputRoot $relative
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
    Copy-Item -LiteralPath $source -Destination $target
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) { throw "Package copy hash mismatch: $relative" }
}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'sw.js'), $worker, $Utf8)
[IO.File]::WriteAllText((Join-Path $OutputRoot 'assets/js/offline.js'), $offline, $Utf8)
Assert-Package $OutputRoot $Files $Stage

if ($Promote) {
    $null = Save-Preview @(Get-PreviewFiles)
    foreach ($relative in $Files) {
        $source = Get-SourcePath $OutputRoot $relative
        $target = Get-SourcePath $Workspace $relative
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
        Copy-Item -LiteralPath $source -Destination $target -Force
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) { throw "Promotion copy hash mismatch: $relative" }
    }
    $readmePath = Join-Path $Workspace 'README.md'
    $readme = Get-Content -LiteralPath $readmePath -Raw
    $readme = $readme.Replace('Full workshop opens ahead of IEEE APEC 2027.', 'The full workshop is available in the web app.')
    $readme = $readme.Replace('**Available now:** Preparation, Overview, and previews of Lab and the completion badge.', '**Available now:** Preparation, Overview, all experiments, Homework, Quiz, and the completion badge.')
    [IO.File]::WriteAllText($readmePath, $readme, $Utf8)
    Write-Output 'Promoted full runtime source locally. The verified Stage 2 source snapshot and release documentation were retained.'
}
Write-Output "Package: $OutputRoot"
Write-Output "Service-worker version: $version"
Write-Output 'No Git commit, push, or deployment was performed.'
