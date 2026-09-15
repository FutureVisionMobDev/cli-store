# Edit this default if your store is on a different domain.
$DefaultStore = "https://appstore.fvcloud.online"

$ErrorActionPreference = "Stop"

function Show-JkStoreBanner {
  Write-Host ""
  Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor DarkCyan
  Write-Host "  ║" -NoNewline -ForegroundColor DarkCyan
  Write-Host "                                          " -NoNewline
  Write-Host "║" -ForegroundColor DarkCyan
  Write-Host @"
       _ _  ______ _____ ___  ____  _____ 
     | | |/ / ___|_   _/ _ \|  _ \| ____|
  _  | | ' /\___ \ | || | | | |_) |  _|  
 | |_| | . \ ___) || || |_| |  _ <| |___ 
  \___/|_|\_\____/ |_| \___/|_| \_\_____|
"@ -ForegroundColor Cyan
  Write-Host "  ║" -NoNewline -ForegroundColor DarkCyan
  Write-Host "     self-hosted app catalog              " -NoNewline -ForegroundColor DarkGray
  Write-Host "║" -ForegroundColor DarkCyan
  Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor DarkCyan
  Write-Host ""
}

function Get-JkStoreManifest {
  param([string]$Store)
  Write-Host "  · fetching catalog from $Store ..." -ForegroundColor DarkGray
  return Invoke-RestMethod -Uri "$Store/apps.json" -Method Get
}

function Show-JkStoreMenu {
  param([string]$Store = $DefaultStore)
  $Store = $Store.TrimEnd("/")
  Show-JkStoreBanner

  $manifest = Get-JkStoreManifest -Store $Store
  $slugs = @($manifest.PSObject.Properties.Name | Sort-Object)
  if ($slugs.Count -eq 0) {
    Write-Host "  ┌──────────────────────────────────────────┐" -ForegroundColor DarkYellow
    Write-Host "  │  catalog empty — upload apps in admin    │" -ForegroundColor Yellow
    Write-Host "  │  $Store/admin" -ForegroundColor Yellow
    Write-Host "  └──────────────────────────────────────────┘" -ForegroundColor DarkYellow
    Write-Host ""
    return
  }

  Write-Host "  ┌──────┬────────────────────┬──────────┬─────────────────────┐" -ForegroundColor DarkCyan
  Write-Host ("  │ {0,-4} │ {1,-18} │ {2,-8} │ {3,-19} │" -f "#", "SLUG", "OS", "NAME") -ForegroundColor White
  Write-Host "  ├──────┼────────────────────┼──────────┼─────────────────────┤" -ForegroundColor DarkCyan

  $i = 1
  $map = @{}
  foreach ($slug in $slugs) {
    $entry = $manifest.$slug
    $osBits = @()
    if ($entry.win) { $osBits += "win" }
    if ($entry.mac) { $osBits += "mac" }
    $osLabel = if ($osBits.Count) { $osBits -join "+" } else { "-" }
    $name = [string]$entry.name
    if ($name.Length -gt 19) { $name = $name.Substring(0, 16) + "..." }
    Write-Host "  │ " -NoNewline -ForegroundColor DarkCyan
    Write-Host ("{0,-4}" -f $i) -NoNewline -ForegroundColor Green
    Write-Host " │ " -NoNewline -ForegroundColor DarkCyan
    Write-Host ("{0,-18}" -f $slug) -NoNewline -ForegroundColor Cyan
    Write-Host " │ " -NoNewline -ForegroundColor DarkCyan
    Write-Host ("{0,-8}" -f $osLabel) -NoNewline -ForegroundColor Gray
    Write-Host " │ " -NoNewline -ForegroundColor DarkCyan
    Write-Host ("{0,-19}" -f $name) -NoNewline -ForegroundColor White
    Write-Host " │" -ForegroundColor DarkCyan
    $map[$i] = $slug
    $i++
  }

  Write-Host "  ├──────┴────────────────────┴──────────┴─────────────────────┤" -ForegroundColor DarkCyan
  Write-Host "  │  Q  quit                                                   │" -ForegroundColor DarkGray
  Write-Host "  └────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
  Write-Host ""

  while ($true) {
    Write-Host "  ▸ " -NoNewline -ForegroundColor Green
    $choice = Read-Host "select #"
    if ([string]::IsNullOrWhiteSpace($choice)) { continue }
    if ($choice -match '^[Qq]$') {
      Write-Host "  · bye." -ForegroundColor DarkGray
      Write-Host ""
      return
    }
    $num = 0
    if (-not [int]::TryParse($choice, [ref]$num) -or -not $map.ContainsKey($num)) {
      Write-Host "  ✗ invalid — pick a number from the table." -ForegroundColor Red
      continue
    }
    Install -App $map[$num] -Store $Store -QuietBanner
    return
  }
}

function Install {
  param(
    [string]$App,
    [string]$Store = $DefaultStore,
    [switch]$QuietBanner
  )

  $Store = $Store.TrimEnd("/")

  if ([string]::IsNullOrWhiteSpace($App)) {
    Show-JkStoreMenu -Store $Store
    return
  }

  if (-not $QuietBanner) { Show-JkStoreBanner }

  Write-Host "  · fetching $App ..." -ForegroundColor DarkGray
  $manifest = Invoke-RestMethod -Uri "$Store/apps.json" -Method Get

  if (-not ($manifest.PSObject.Properties.Name -contains $App)) {
    $available = @($manifest.PSObject.Properties.Name) -join ", "
    if (-not $available) { $available = "(none)" }
    Write-Host "  ✗ App '$App' not found. Available: $available" -ForegroundColor Red
    exit 1
  }

  $entry = $manifest.$App
  if (-not $entry.win) {
    Write-Host "  ✗ App '$App' has no Windows installer." -ForegroundColor Red
    exit 1
  }

  $win = $entry.win
  $url = [string]$win.url
  $version = [string]$win.version
  $expected = ([string]$win.sha256).ToLowerInvariant()
  $args = [string]$win.args

  $ext = [System.IO.Path]::GetExtension(([Uri]$url).AbsolutePath)
  if (-not $ext) { $ext = ".exe" }
  $dest = Join-Path $env:TEMP ("{0}-{1}{2}" -f $App, $version, $ext)

  Write-Host "  ↓ downloading $App $version" -ForegroundColor Cyan
  $expectedSize = 0
  if ($win.PSObject.Properties.Name -contains "size") {
    [void][int64]::TryParse([string]$win.size, [ref]$expectedSize)
  }
  $destDir = Split-Path -Parent $dest
  if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
  if (Test-Path $dest) { Remove-Item -Force $dest -ErrorAction SilentlyContinue }

  # Progress + resume (Cloudflare often cuts large files mid-transfer)
  $try = 0
  while ($true) {
    $try++
    if ($try -gt 40) {
      Write-Host "  ✗ download incomplete after $try tries" -ForegroundColor Red
      exit 1
    }
    $existing = 0
    if (Test-Path $dest) { $existing = (Get-Item $dest).Length }
    try {
      $req = [System.Net.HttpWebRequest]::Create($url)
      $req.Method = "GET"
      $req.AllowAutoRedirect = $true
      $req.Timeout = 600000
      $req.ReadWriteTimeout = 600000
      if ($existing -gt 0) {
        $req.AddRange($existing)
      }
      $resp = $req.GetResponse()
      $total = $existing
      if ($resp.ContentLength -ge 0) {
        $total = $existing + $resp.ContentLength
      } elseif ($expectedSize -gt 0) {
        $total = $expectedSize
      }
      $stream = $resp.GetResponseStream()
      $mode = if ($existing -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
      $fs = [System.IO.File]::Open($dest, $mode)
      $buffer = New-Object byte[] (1024 * 256)
      $readTotal = $existing
      while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $fs.Write($buffer, 0, $n)
        $readTotal += $n
        if ($total -gt 0) {
          $pct = [math]::Min(100, [int](($readTotal * 100) / $total))
          Write-Progress -Activity "Downloading $App" -Status ("{0:N1} MB / {1:N1} MB" -f ($readTotal/1MB), ($total/1MB)) -PercentComplete $pct
        } else {
          Write-Progress -Activity "Downloading $App" -Status ("{0:N1} MB" -f ($readTotal/1MB)) -PercentComplete -1
        }
      }
      $fs.Close()
      $stream.Close()
      $resp.Close()
      Write-Progress -Activity "Downloading $App" -Completed
    } catch {
      Write-Progress -Activity "Downloading $App" -Completed
      Write-Host "  · interrupted ($($_.Exception.Message)) — resume try $try..." -ForegroundColor DarkYellow
      Start-Sleep -Seconds 1
      continue
    }
    $got = (Get-Item $dest).Length
    if ($expectedSize -gt 0) {
      if ($got -eq $expectedSize) { break }
      Write-Host "  · partial ($got / $expectedSize) — resume try $try..." -ForegroundColor DarkYellow
      Start-Sleep -Seconds 1
      continue
    }
    if ($got -gt 0) { break }
  }

  Write-Host "  ⚙ verifying SHA256" -ForegroundColor Cyan
  $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected) {
    Remove-Item -Force $dest -ErrorAction SilentlyContinue
    Write-Host "  ✗ checksum mismatch — abort." -ForegroundColor Red
    exit 1
  }

  Write-Host "  ▶ installing..." -ForegroundColor Cyan
  if ($ext -ieq ".zip") {
    $extractRoot = Join-Path $env:TEMP ("{0}-{1}-extracted" -f $App, $version)
    if (Test-Path $extractRoot) {
      Remove-Item -Recurse -Force $extractRoot -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $extractRoot | Out-Null
    Write-Host "  📦 extracting zip..." -ForegroundColor Cyan
    Expand-Archive -Path $dest -DestinationPath $extractRoot -Force
    Remove-Item -Force $dest -ErrorAction SilentlyContinue

    $launch = $null
    if (-not [string]::IsNullOrWhiteSpace($args)) {
      $candidate = Join-Path $extractRoot ($args.Trim().TrimStart("\", "/"))
      if (Test-Path -LiteralPath $candidate) { $launch = (Resolve-Path -LiteralPath $candidate).Path }
    }
    if (-not $launch) {
      $exes = @(Get-ChildItem -Path $extractRoot -Recurse -File -Filter "*.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '(?i)(uninstall|setup|installer|update|crash)' } |
        Sort-Object { $_.FullName.Length }, FullName)
      if ($exes.Count -eq 1) {
        $launch = $exes[0].FullName
      } elseif ($exes.Count -gt 1) {
        $rootExes = @($exes | Where-Object { $_.DirectoryName -eq $extractRoot })
        if ($rootExes.Count -eq 1) { $launch = $rootExes[0].FullName }
        else {
          $byName = @($exes | Where-Object { $_.BaseName -ieq $App })
          if ($byName.Count -ge 1) { $launch = $byName[0].FullName }
          else { $launch = $exes[0].FullName }
        }
      }
    }

    if (-not $launch) {
      Write-Host "  ✗ no .exe found inside zip. Extracted to: $extractRoot" -ForegroundColor Red
      exit 1
    }

    Write-Host "  ▶ launching $($launch.Replace($extractRoot, '.'))" -ForegroundColor Cyan
    Start-Process -FilePath $launch -WorkingDirectory (Split-Path -Parent $launch)
    Write-Host "  ✓ done — $App $version extracted + launched." -ForegroundColor Green
    Write-Host "  · files stay at: $extractRoot" -ForegroundColor DarkGray
    Write-Host ""
    return
  }

  if ($ext -ieq ".msi") {
    $msiArgs = @("/i", $dest) + ($args -split "\s+" | Where-Object { $_ })
    Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -NoNewWindow
  } else {
    if ([string]::IsNullOrWhiteSpace($args)) {
      Start-Process -FilePath $dest -Wait -NoNewWindow
    } else {
      Start-Process -FilePath $dest -ArgumentList $args -Wait -NoNewWindow
    }
  }

  Remove-Item -Force $dest -ErrorAction SilentlyContinue
  Write-Host "  ✓ done — $App $version installed." -ForegroundColor Green
  Write-Host ""
}

# One-liner menu:  irm https://appstore…/install.ps1 | iex
# Direct install:  $env:JK_APP='slug'; irm https://appstore…/install.ps1 | iex
#              or: irm …/install.ps1 | iex; Install -App slug   (same session)
$JkApp = $env:JK_APP
if (-not $JkApp -and $args.Count -gt 0) { $JkApp = [string]$args[0] }
if ($JkApp) {
  Install -App $JkApp
} else {
  Install
}
