# CleanWindowsDirtyApp - remote bootstrap (ASCII only, safe for: irm URL | iex)
#
# Published at https://cleanwindowsdirtyapp.pages.dev/ (Cloudflare Pages).
# This file and src/CleanWindowsDirtyApp.ps1 must stay in the same hosted tree;
# $Sources below points at the directory that holds the main script.
# Users then run ONE command:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://cleanwindowsdirtyapp.pages.dev/bootstrap.ps1 | iex"
#
# Why a bootstrap instead of piping the main script directly:
#   * the main script uses $PSScriptRoot and is UTF-8 with BOM -> it must be saved
#     to a file and started with -File, not executed from a string;
#   * HKLM cleanup needs admin -> this bootstrap re-launches elevated;
#   * downloads can be verified before anything is executed.

& {
    # First URL is the primary source; the rest are tried in order when it fails.
    # GitHub raw and the four URL-prefix mirrors are fallbacks for the Pages host.
    $Sources = @(
        'https://cleanwindowsdirtyapp.pages.dev/src'
        'https://raw.githubusercontent.com/chgy188/cleanwindowsdirtyapp/main/src'
        'https://gh-proxy.org/https://raw.githubusercontent.com/chgy188/cleanwindowsdirtyapp/main/src'
        'https://gh-proxy.com/https://raw.githubusercontent.com/chgy188/cleanwindowsdirtyapp/main/src'
        'https://github.tbap.top/https://raw.githubusercontent.com/chgy188/cleanwindowsdirtyapp/main/src'
        'https://ghfile-geekertao.top/https://raw.githubusercontent.com/chgy188/cleanwindowsdirtyapp/main/src'
    )

    # SHA256 of the hosted main script. MUST be refreshed on every release.
    # Get it with: (Get-FileHash .\src\CleanWindowsDirtyApp.ps1 -Algorithm SHA256).Hash
    $Sha256 = '48FE42476DF500D47464E853432B13AABE41EB9B07DEE13DAC79F97E09186F2F'

    $ErrorActionPreference = 'Stop'
    $ProgressPreference   = 'SilentlyContinue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $Root   = Join-Path $env:USERPROFILE 'CleanWindowsDirtyApp'
    $Target = Join-Path $Root 'CleanWindowsDirtyApp.ps1'
    $Temp   = $Target + '.tmp'

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Write-Host 'Downloading CleanWindowsDirtyApp ...'

    $ok = $false
    foreach ($src in $Sources) {
        $url = $src.TrimEnd('/') + '/CleanWindowsDirtyApp.ps1'
        try {
            Write-Host ('  trying ' + $url)
            Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $url -OutFile $Temp -UseBasicParsing -TimeoutSec 60
            if (-not (Test-Path -LiteralPath $Temp)) { continue }
            if ((Get-Item -LiteralPath $Temp).Length -lt 1024) { continue }

            # Guard against an HTML error page returned by a proxy/CDN.
            $text = Get-Content -LiteralPath $Temp -Raw -Encoding UTF8
            if ($text -notmatch 'CleanWindowsDirtyApp') { continue }
            $ok = $true
            break
        } catch {
            Write-Host ('  failed: ' + $_.Exception.Message)
        }
    }
    if (-not $ok) {
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        throw 'All download sources failed. Nothing was executed.'
    }

    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $Temp -Algorithm SHA256).Hash
        if ($actual -ne $Sha256.Trim().ToUpperInvariant()) {
            Remove-Item -LiteralPath $Temp -Force
            throw 'SHA256 mismatch - download aborted.'
        }
        Write-Host '  checksum OK'
    }

    Move-Item -LiteralPath $Temp -Destination $Target -Force
    Write-Host ('  saved to ' + $Target)

    $id      = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $Target +
               '" -Mode Menu -OutputRoot "' + $Root + '"'

    if ($isAdmin) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Wait -NoNewWindow
    } else {
        Write-Host 'Requesting administrator privileges ...'
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs
    }
}
