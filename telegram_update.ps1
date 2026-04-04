#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
Cron/Task Scheduler-friendly wrapper for telegram_update.py + git commit/push.

.DESCRIPTION
Default layout:
  <repo>\telegram_update.ps1
  <repo>\telegram_update.py
  <repo>\unblock.txt
  <repo>\telegram_update.env   (optional, KEY=VALUE format)

Example telegram_update.env:
  TELEGRAM_API_ID=12345678
  TELEGRAM_API_HASH=0123456789abcdef0123456789abcdef
  TELEGRAM_SESSION_STRING=...

First interactive auth (one time, outside Task Scheduler):
  $env:TELEGRAM_API_ID="..."
  $env:TELEGRAM_API_HASH="..."
  python .\telegram_update.py --unblock .\unblock.txt --session-file .\.telegram_update.session

Then Task Scheduler can run this wrapper with NO_INTERACTIVE=1.
#>

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[telegram_update] $Message"
}

function Write-Err {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine("[telegram_update][ERR] $Message")
}

function Get-EnvValue {
    param([Parameter(Mandatory = $true)][string]$Name)
    $item = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }
    return [string]$item.Value
}

function Get-Setting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Default
    )
    $value = Get-EnvValue -Name $Name
    if ([string]::IsNullOrEmpty($value)) {
        return $Default
    }
    return $value
}

function Test-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    return $Value -match "^(1|true|yes|on)$"
}

function Import-SimpleEnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }

        if ($line.StartsWith("export ")) {
            $line = $line.Substring(7).Trim()
        }

        $match = [regex]::Match($line, "^(?<key>[A-Za-z_][A-Za-z0-9_]*)=(?<value>.*)$")
        if (-not $match.Success) {
            continue
        }

        $key = $match.Groups["key"].Value
        $value = $match.Groups["value"].Value.Trim()

        if ($value.Length -ge 2) {
            $quote = $value.Substring(0, 1)
            if (($quote -eq "'" -or $quote -eq '"') -and $value.EndsWith($quote)) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        Set-Item -Path "Env:$key" -Value $value
    }
}

function Resolve-PythonCommand {
    $configured = Get-EnvValue -Name "PYTHON_BIN"
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $cmd = Get-Command -Name $configured -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            return [pscustomobject]@{ Path = $cmd.Source; PrefixArgs = @() }
        }
        if (Test-Path -LiteralPath $configured -PathType Leaf) {
            return [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $configured).Path; PrefixArgs = @() }
        }
        throw "Python not found: $configured"
    }

    $python = Get-Command -Name "python" -ErrorAction SilentlyContinue
    if ($null -ne $python) {
        return [pscustomobject]@{ Path = $python.Source; PrefixArgs = @() }
    }

    $py = Get-Command -Name "py" -ErrorAction SilentlyContinue
    if ($null -ne $py) {
        return [pscustomobject]@{ Path = $py.Source; PrefixArgs = @("-3") }
    }

    throw "Python not found: python or py"
}

function Resolve-GitCommand {
    $configured = Get-EnvValue -Name "GIT_BIN"
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $cmd = Get-Command -Name $configured -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            return [pscustomobject]@{ Path = $cmd.Source; PrefixArgs = @() }
        }
        if (Test-Path -LiteralPath $configured -PathType Leaf) {
            return [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $configured).Path; PrefixArgs = @() }
        }
        throw "Git not found: $configured"
    }

    $git = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        throw "Git not found: git"
    }

    return [pscustomobject]@{ Path = $git.Source; PrefixArgs = @() }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$PrefixArgs = @(),
        [string[]]$Arguments = @(),
        [switch]$CaptureOutput
    )

    if ($CaptureOutput) {
        $output = & $Path @PrefixArgs @Arguments
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = @($output)
        }
    }

    & $Path @PrefixArgs @Arguments
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = @()
    }
}

function Ensure-Success {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Result.ExitCode -ne 0) {
        throw $Message
    }
}

function Ensure-TrailingSeparator {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path.EndsWith("\") -or $Path.EndsWith("/")) {
        return $Path
    }
    return "$Path\"
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $baseUri = [Uri](Ensure-TrailingSeparator -Path ([System.IO.Path]::GetFullPath($BasePath)))
    $targetUri = [Uri]([System.IO.Path]::GetFullPath($TargetPath))
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    return [Uri]::UnescapeDataString($relativeUri.ToString()).Replace("/", "\")
}

function Main {
    $scriptDir = $PSScriptRoot
    $defaultEnvFile = Join-Path $scriptDir "telegram_update.env"
    $envFile = Get-Setting -Name "ENV_FILE" -Default $defaultEnvFile
    Import-SimpleEnvFile -Path $envFile

    $repoDir = Get-Setting -Name "REPO_DIR" -Default $scriptDir
    $updater = Get-Setting -Name "UPDATER" -Default (Join-Path $scriptDir "telegram_update.py")
    $unblockFile = Get-Setting -Name "UNBLOCK_FILE" -Default (Join-Path $repoDir "unblock.txt")
    $sessionFile = Get-Setting -Name "SESSION_FILE" -Default (Join-Path $scriptDir ".telegram_update.session")
    $remote = Get-Setting -Name "REMOTE" -Default "origin"
    $branch = Get-Setting -Name "BRANCH" -Default "main"
    $commitPrefix = Get-Setting -Name "COMMIT_PREFIX" -Default "telegram: refresh auto IP block"
    $lockFile = Get-Setting -Name "LOCK_FILE" -Default (Join-Path $scriptDir ".telegram_update.lock")
    $noInteractive = Test-Truthy -Value (Get-Setting -Name "NO_INTERACTIVE" -Default "1")
    $pullRebase = Test-Truthy -Value (Get-Setting -Name "PULL_REBASE" -Default "1")

    $apiId = Get-EnvValue -Name "TELEGRAM_API_ID"
    $apiHash = Get-EnvValue -Name "TELEGRAM_API_HASH"

    if ([string]::IsNullOrWhiteSpace($apiId)) {
        Write-Err "Set TELEGRAM_API_ID in environment or telegram_update.env"
        return 2
    }
    if ([string]::IsNullOrWhiteSpace($apiHash)) {
        Write-Err "Set TELEGRAM_API_HASH in environment or telegram_update.env"
        return 2
    }

    if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
        Write-Err "telegram_update.py not found: $updater"
        return 1
    }
    if (-not (Test-Path -LiteralPath $unblockFile -PathType Leaf)) {
        Write-Err "unblock.txt not found: $unblockFile"
        return 1
    }

    try {
        $python = Resolve-PythonCommand
        $git = Resolve-GitCommand
    }
    catch {
        Write-Err $_.Exception.Message
        return 1
    }

    $lockStream = $null
    try {
        try {
            $lockDir = Split-Path -Parent $lockFile
            if (-not [string]::IsNullOrWhiteSpace($lockDir)) {
                New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
            }
            $lockStream = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch {
            Write-Log "Another run is already active. Exiting."
            return 0
        }

        Push-Location -LiteralPath $repoDir
        try {
            $repoTopResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("rev-parse", "--show-toplevel") -CaptureOutput
            Ensure-Success -Result $repoTopResult -Message "Failed to determine Git repo root."
            $repoTop = $repoTopResult.Output[-1].Trim()

            $unblockFull = (Resolve-Path -LiteralPath $unblockFile).Path
            $unblockGitPath = (Get-RelativePath -BasePath $repoTop -TargetPath $unblockFull).Replace("\", "/")

            $unstagedResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("diff", "--name-only") -CaptureOutput
            Ensure-Success -Result $unstagedResult -Message "Failed to inspect unstaged changes."
            $stagedResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("diff", "--cached", "--name-only") -CaptureOutput
            Ensure-Success -Result $stagedResult -Message "Failed to inspect staged changes."

            $dirtyFiles = @(
                $unstagedResult.Output
                $stagedResult.Output
            ) |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique

            $dirtyOther = @($dirtyFiles | Where-Object { ($_.Replace("\", "/")) -ne $unblockGitPath })
            if ($dirtyOther.Count -gt 0) {
                Write-Err "Repository has unrelated local changes. Commit/stash them before using the runner."
                foreach ($path in $dirtyOther) {
                    [Console]::Error.WriteLine($path)
                }
                return 1
            }

            if ($pullRebase) {
                Write-Log "Pulling latest changes from $remote/$branch"
                $fetchResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("fetch", $remote, $branch)
                Ensure-Success -Result $fetchResult -Message "git fetch failed"
                $pullResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("pull", "--rebase", $remote, $branch)
                Ensure-Success -Result $pullResult -Message "git pull --rebase failed"
            }

            $beforeResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("hash-object", $unblockGitPath) -CaptureOutput
            Ensure-Success -Result $beforeResult -Message "Failed to hash unblock.txt before update."
            $beforeSum = $beforeResult.Output[-1].Trim()

            $pythonArgs = @($updater, "--unblock", $unblockFile, "--session-file", $sessionFile)
            if (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -Name "TELEGRAM_SESSION_STRING"))) {
                $pythonArgs += @("--session-string", (Get-EnvValue -Name "TELEGRAM_SESSION_STRING"))
            }
            if ($noInteractive) {
                $pythonArgs += "--no-interactive"
            }

            Write-Log "Running telegram_update.py"
            $updateResult = Invoke-Native -Path $python.Path -PrefixArgs $python.PrefixArgs -Arguments $pythonArgs
            if ($updateResult.ExitCode -ne 0) {
                Write-Err "telegram_update.py failed"
                return $updateResult.ExitCode
            }

            $afterResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("hash-object", $unblockGitPath) -CaptureOutput
            Ensure-Success -Result $afterResult -Message "Failed to hash unblock.txt after update."
            $afterSum = $afterResult.Output[-1].Trim()

            if ($beforeSum -eq $afterSum) {
                Write-Log "unblock.txt unchanged; nothing to commit"
                return 0
            }

            $addResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("add", "--", $unblockGitPath)
            Ensure-Success -Result $addResult -Message "git add failed"

            $quietResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("diff", "--cached", "--quiet", "--", $unblockGitPath)
            if ($quietResult.ExitCode -eq 0) {
                Write-Log "No staged changes after update"
                return 0
            }
            if ($quietResult.ExitCode -gt 1) {
                throw "git diff --cached --quiet failed"
            }

            $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $commitMessage = "$commitPrefix ($stamp)"
            Write-Log "Committing changes"
            $commitResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("commit", "-m", $commitMessage)
            Ensure-Success -Result $commitResult -Message "git commit failed"

            Write-Log "Pushing to $remote/$branch"
            $pushResult = Invoke-Native -Path $git.Path -PrefixArgs $git.PrefixArgs -Arguments @("push", $remote, $branch)
            Ensure-Success -Result $pushResult -Message "git push failed"

            Write-Log "Done"
            return 0
        }
        finally {
            Pop-Location
        }
    }
    catch {
        Write-Err $_.Exception.Message
        return 1
    }
    finally {
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }
    }
}

exit (Main)
