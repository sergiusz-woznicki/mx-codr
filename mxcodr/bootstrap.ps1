<#
.SYNOPSIS
  Sets a Windows machine up for the Mendix MDL harness, then installs it.

.DESCRIPTION
  install.sh does everything else, but it is a bash script, so it cannot install
  the shell it needs. That is the one job of this file: get Git for Windows,
  Python and Node in place with winget, then hand over to bash install.sh
  --with-deps, which installs the rest (playwright-cli, its browser, mxcli,
  MxBuild) and lands the harness.

  Docker Desktop and the JDK are reported, never installed: both want a reboot
  or a licence click, so a script that "finished" without them would have lied.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File dist\bootstrap.ps1 C:\Mendix\MyApp
#>

[CmdletBinding()]
param(
  # Where to install. Defaults to the directory the bundle sits in.
  [Parameter(Position = 0)]
  [string]$Target = (Split-Path -Parent $PSScriptRoot),

  # Skip the winget stage; only refresh PATH and run install.sh.
  [switch]$SkipWinget
)

$ErrorActionPreference = 'Stop'

function Write-Step($text) { Write-Host "  - $text" -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host "  + $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "  ! $text" -ForegroundColor Yellow }

# winget only writes the new PATH to the registry; this process still has the old
# one, so a freshly installed python is invisible until the value is re-read.
function Update-PathFromRegistry {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Test-Command($name) {
  $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

# Get-Command is not enough for Python. Windows ships an App Execution Alias at
# WindowsApps\python.exe that resolves, does nothing, and opens the Microsoft
# Store -- so the interpreter is asked to run. And winget accepts the python.org
# default of *not* adding python to the PATH, so a real Python may be installed
# and invisible; those directories are searched too, and the winner is put on the
# PATH for the bash that follows.
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

Write-Host ''
Write-Host '  MENDFIXER  ' -ForegroundColor White -NoNewline
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

  # id, the command that proves it is there, and what it is for.
  $packages = @(
    @{ Id = 'Git.Git';             Probe = 'git';    Why = 'Git Bash - the shell the harness runs in' },
    @{ Id = 'Python.Python.3.12';  Probe = 'python'; Why = 'the hook merges and the model checkers'; Resolver = 'Resolve-Python' },
    @{ Id = 'OpenJS.NodeJS.LTS';   Probe = 'node';   Why = 'playwright-cli, which drives the browser tests' }
  )

  foreach ($package in $packages) {
    $present = if ($package.Resolver) { [bool](& $package.Resolver) } else { Test-Command $package.Probe }
    if ($present) {
      Write-Ok "$($package.Id) already present"
      continue
    }
    Write-Step "installing $($package.Id)  ($($package.Why))"
    & winget install -e --accept-package-agreements --accept-source-agreements `
        --disable-interactivity --id $package.Id
    Update-PathFromRegistry
    $present = if ($package.Resolver) { [bool](& $package.Resolver) } else { Test-Command $package.Probe }
    if ($present) {
      Write-Ok "$($package.Id) installed"
    } else {
      Write-Warn "$($package.Id) did not become available on the PATH."
      Write-Warn 'Open a new terminal and re-run; a reboot is occasionally needed.'
    }
  }
}

Update-PathFromRegistry

# A Python that is installed but not on the PATH is invisible to bash, so put its
# directory on the PATH of the process that is about to launch bash.
$python = Resolve-Python
if ($python) {
  $pythonDir = Split-Path -Parent $python
  if (($env:Path -split ';') -notcontains $pythonDir) {
    $env:Path = "$pythonDir;$env:Path"
    Write-Ok "python: $python  (added to PATH for this run)"
    Write-Warn "That directory is not on your permanent PATH. To fix it for good:"
    Write-Warn "  setx PATH \"$pythonDir;%PATH%\""
  } else {
    Write-Ok "python: $python"
  }
} else {
  Write-Warn 'No working Python found. install.sh will stop and say so.'
}

# --- 2. find a real Git Bash -------------------------------------------------
# `where bash` answers C:\Windows\System32\bash.exe on Windows 11, and that is the
# WSL launcher, not Git Bash: a different filesystem, no mxcli.exe, and a baffling
# failure ten minutes later. So Git's own directories come first, and anything
# under System32 is rejected outright.
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
function ConvertTo-BashPath($path) {
  $full = (Resolve-Path -LiteralPath $path).Path
  # C:\Mendix\App -> /c/Mendix/App, the form Git Bash uses for a drive.
  '/' + $full.Substring(0, 1).ToLower() + $full.Substring(2).Replace('\', '/')
}

if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Force -Path $Target | Out-Null }
$bundlePath = ConvertTo-BashPath $PSScriptRoot
$targetPath = ConvertTo-BashPath $Target

Write-Step "installing the harness into $Target"
Write-Host ''
& $bash -c "cd '$bundlePath' && bash install.sh '$targetPath' --with-deps"
$installExit = $LASTEXITCODE

# --- 4. the two this script will not install ---------------------------------
Write-Host ''
# install.sh offers to install Docker and waits with you for the daemon, but only
# when it can ask -- which needs a console. Say so rather than repeating the offer.
# Only mention Docker when the installer did not already settle the question. Saying
# "Docker is still missing" to someone who just chose the no-Docker mode is noise,
# and the old wording also claimed mx check needs a container, which it never did.
$harnessEnv = Join-Path $Target 'tests\harness.env'
$noDocker = (Test-Path $harnessEnv) -and (Select-String -Path $harnessEnv -Pattern 'MDL_NO_DOCKER=1' -Quiet)
if ($noDocker) {
  Write-Ok 'Set up without Docker — see tests\harness.env for what it uses instead.'
} elseif (-not (Test-Command 'docker')) {
  Write-Warn 'No Docker and no local Mendix installation were found, so the app has'
  Write-Warn 'no database to run against. Install Docker Desktop, or install Mendix'
  Write-Warn 'Studio Pro and a PostgreSQL, then re-run:'
  Write-Warn '  bash dist/install.sh . --with-deps'
}
# Studio Pro installs a JDK as its own prerequisite, and on Windows it is routinely
# not on the PATH -- three of them were installed on the test machine and none was.
# So look before telling anyone to install anything.
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
    Write-Warn "  setx PATH \"$(Split-Path -Parent $java.FullName);%PATH%\""
  } else {
    Write-Warn 'No JDK found. Running the app locally needs one matching the project:'
    Write-Warn '  winget install -e --id EclipseAdoptium.Temurin.21.JDK'
  }
}

exit $installExit
