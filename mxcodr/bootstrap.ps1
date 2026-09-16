<#
.SYNOPSIS
  Windows bootstrap: installs Git, Python and Node with winget, then runs install.sh --with-deps in Git Bash.

.PARAMETER Target
  Mendix project to install into (created if missing). Default: parent of the bundle folder.

.PARAMETER SkipWinget
  Skip the winget stage.

.OUTPUTS
  Exit 1 when winget or Git Bash is missing; otherwise install.sh's exit code.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File mxcodr\bootstrap.ps1 C:\Mendix\MyApp
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Target = (Split-Path -Parent $PSScriptRoot),

  [switch]$SkipWinget
)

# Native programs exiting non-zero do not stop the script; check $LASTEXITCODE.
$ErrorActionPreference = 'Stop'

function Write-Step($text) { Write-Host "  - $text" -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host "  + $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "  ! $text" -ForegroundColor Yellow }

# winget writes PATH only to the registry; re-read it into this process.
function Update-PathFromRegistry {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Test-Command($name) {
  $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

# Resolve-Python -- path of a Python that really runs, or $null.
# Skips the WindowsApps Store alias; also searches install dirs not on PATH.
function Resolve-Python {
  foreach ($name in @('python3', 'python', 'py')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $command) { continue }
    if ($command.Source -like '*\WindowsApps\*') { continue }
    & $command.Source -c 'import json,sys' 2>$null
    if ($LASTEXITCODE -eq 0) { return $command.Source }
  }
  $roots = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)}
  ) | Where-Object { $_ -and (Test-Path $_) }
  foreach ($root in $roots) {
    $found = Get-ChildItem -Path $root -Filter 'python.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
             Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) {
      & $found.FullName -c 'import json,sys' 2>$null
      if ($LASTEXITCODE -eq 0) { return $found.FullName }
    }
  }
  return $null
}

# Test-PackagePresent <package> -- true when the package's Resolver (or its Probe command) finds it.
function Test-PackagePresent($package) {
  if ($package.Resolver) { [bool](& $package.Resolver) } else { Test-Command $package.Probe }
}

# --- main ---
Write-Host ''
Write-Host '  MX-CODR  ' -ForegroundColor White -NoNewline
Write-Host 'Windows bootstrap' -ForegroundColor DarkGray
Write-Host ''

# --- 1. winget stage ---------------------------------------------------------
if (-not $SkipWinget) {
  if (-not (Test-Command 'winget')) {
    Write-Warn 'winget was not found. It ships with App Installer on Windows 10 1809+.'
    Write-Warn 'Install "App Installer" from the Microsoft Store, or install Git for'
    Write-Warn 'Windows, Python 3 and Node.js by hand, then re-run with -SkipWinget.'
    exit 1
  }

  $packages = @(
    @{ Id = 'Git.Git';             Probe = 'git';    Why = 'Git Bash - the shell the harness runs in' },
    @{ Id = 'Python.Python.3.12';  Probe = 'python'; Why = 'the hook merges and the model checkers'; Resolver = 'Resolve-Python' },
    @{ Id = 'OpenJS.NodeJS.LTS';   Probe = 'node';   Why = 'playwright-cli, which drives the browser tests' }
  )

  foreach ($package in $packages) {
    if (Test-PackagePresent $package) {
      Write-Ok "$($package.Id) already present"
      continue
    }
    Write-Step "installing $($package.Id)  ($($package.Why))"
    & winget install -e --accept-package-agreements --accept-source-agreements `
        --disable-interactivity --id $package.Id
    Update-PathFromRegistry
    if (Test-PackagePresent $package) {
      Write-Ok "$($package.Id) installed"
    } else {
      Write-Warn "$($package.Id) did not become available on the PATH."
      Write-Warn 'Open a new terminal and re-run; a reboot is occasionally needed.'
    }
  }
}

Update-PathFromRegistry

# Put the resolved Python on PATH so bash sees it.
$python = Resolve-Python
if ($python) {
  $pythonDir = Split-Path -Parent $python
  if (($env:Path -split ';') -notcontains $pythonDir) {
    $env:Path = "$pythonDir;$env:Path"
    Write-Ok "python: $python  (added to PATH for this run)"
    Write-Warn "That directory is not on your permanent PATH. To fix it for good:"
    Write-Warn "  setx PATH `"$pythonDir;%PATH%`""
  } else {
    Write-Ok "python: $python"
  }
} else {
  Write-Warn 'No working Python found. install.sh will stop and say so.'
}

# --- 2. find a real Git Bash -------------------------------------------------
# `where bash` can return System32\bash.exe, the WSL launcher: reject it, prefer Git's own.
$bashCandidates = @(
  (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
  (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
) + @(Get-Command bash.exe -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })

$bash = $bashCandidates |
  Where-Object { $_ -and (Test-Path $_) -and ($_ -notmatch '\\System32\\') } |
  Select-Object -First 1

if (-not $bash) {
  Write-Warn 'No Git Bash found. Install Git for Windows from https://git-scm.com/download/win'
  exit 1
}
Write-Ok "bash: $bash"

# --- 3. hand over to install.sh ---------------------------------------------
# ConvertTo-BashPath <path> -- C:\Mendix\App -> /c/Mendix/App
function ConvertTo-BashPath($path) {
  $full = (Resolve-Path -LiteralPath $path).Path
  '/' + $full.Substring(0, 1).ToLower() + $full.Substring(2).Replace('\', '/')
}

if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Force -Path $Target | Out-Null }
$bundlePath = ConvertTo-BashPath $PSScriptRoot
$targetPath = ConvertTo-BashPath $Target

Write-Step "installing the harness into $Target"
Write-Host ''
& $bash -c "cd '$bundlePath' && bash install.sh '$targetPath' --with-deps"
$installExit = $LASTEXITCODE

# --- 4. follow-up: the two this script does not install ----------------------
Write-Host ''
# install.sh installs Docker; only warn if it neither did nor chose no-Docker mode.
$harnessEnv = Join-Path $Target 'tests\harness.env'
$noDocker = (Test-Path $harnessEnv) -and (Select-String -Path $harnessEnv -Pattern 'MDL_NO_DOCKER=1' -Quiet)
if ($noDocker) {
  Write-Ok 'Set up without Docker — see tests\harness.env for what it uses instead.'
} elseif (-not (Test-Command 'docker')) {
  Write-Warn 'No Docker and no local Mendix installation were found, so the app has'
  Write-Warn 'no database to run against. Install Docker Desktop, or install Mendix'
  Write-Warn 'Studio Pro and a PostgreSQL, then re-run:'
  Write-Warn '  bash mxcodr/install.sh . --with-deps'
}
# Studio Pro's JDK is often installed but not on PATH, so search before advising an install.
if (-not (Test-Command 'java')) {
  $javaRoots = @($env:JAVA_HOME, 'C:\Program Files', 'C:\Program Files (Arm)', 'C:\Program Files (x86)') |
               Where-Object { $_ -and (Test-Path $_) }
  $java = $null
  foreach ($root in $javaRoots) {
    $java = Get-ChildItem -Path $root -Filter 'java.exe' -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if ($java) { break }
  }
  if ($java) {
    Write-Warn "A JDK is installed but not on the PATH: $($java.FullName)"
    Write-Warn "  `./mxcli.exe run --local` needs it there. To fix it for good:"
    Write-Warn "  setx PATH `"$(Split-Path -Parent $java.FullName);%PATH%`""
  } else {
    Write-Warn 'No JDK found. Running the app locally needs one matching the project:'
    Write-Warn '  winget install -e --id EclipseAdoptium.Temurin.21.JDK'
  }
}

exit $installExit
