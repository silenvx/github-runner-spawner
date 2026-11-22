# Runs one GitHub Actions job on this machine with a just-in-time runner config.
#
# stdin:  the encoded JIT config on one line.
# -Stop:  stops every runner process started from RunnerDir and clears the work folder.
#
# dispatch.py copies this file into RunnerDir and runs it over ssh.
param(
    [Parameter(Mandatory = $true)][string]$RunnerDir,
    [switch]$Stop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$RunnerDir = $RunnerDir.TrimEnd('\')
$workDir = Join-Path $RunnerDir '_work'
$wrapperName = Split-Path -Leaf $PSCommandPath

function Write-Log([string]$Message) {
    Write-Output ('[{0}] {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC'), $Message)
}

# The pool runs one runner at a time, so anything still alive here belongs to an abandoned run
function Stop-RunnerProcesses {
    $self = Get-CimInstance Win32_Process -Filter "ProcessId = $PID"
    $keep = @($PID, $self.ParentProcessId)
    $prefix = $RunnerDir + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $keep -notcontains $_.ProcessId -and (
            ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) -or
            ($_.CommandLine -and $_.CommandLine.IndexOf($wrapperName, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
            ($_.Name -eq 'cmd.exe' -and $_.CommandLine -and
                $_.CommandLine.IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        )
    } | ForEach-Object {
        Write-Log "Stopping $($_.Name) ($($_.ProcessId))"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Clear-Work {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (-not (Test-Path -LiteralPath $workDir)) { return }
        # The \\?\ prefix lets rd delete paths longer than MAX_PATH (deep node_modules and the like)
        & cmd.exe /d /c "rd /s /q `"\\?\$workDir`"" 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $workDir)) { return }
        Start-Sleep -Seconds 2
    }
    throw "Could not remove $workDir"
}

if ($Stop) {
    Stop-RunnerProcesses
    Clear-Work
    exit 0
}

$jitConfig = [Console]::In.ReadLine()
if ([string]::IsNullOrWhiteSpace($jitConfig)) {
    Write-Log 'ERROR: no JIT config on stdin'
    exit 2
}

Stop-RunnerProcesses
Clear-Work
# Leftovers from a crashed run would otherwise be read as this runner's identity
foreach ($file in '.runner', '.credentials', '.credentials_rsaparams') {
    Remove-Item -LiteralPath (Join-Path $RunnerDir $file) -Force -ErrorAction SilentlyContinue
}
$diagDir = Join-Path $RunnerDir '_diag'
if (Test-Path -LiteralPath $diagDir) {
    Get-ChildItem -LiteralPath $diagDir -File |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# The runner masks ACTIONS_RUNNER_INPUT_JITCONFIG in its logs and removes it from the job environment
$env:ACTIONS_RUNNER_INPUT_JITCONFIG = $jitConfig
$jitConfig = $null
$exitCode = 1
try {
    Write-Log 'Starting runner'
    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop'
    $ErrorActionPreference = 'Continue'
    & (Join-Path $RunnerDir 'run.cmd')
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = 'Stop'
    Remove-Item -LiteralPath Env:ACTIONS_RUNNER_INPUT_JITCONFIG -ErrorAction SilentlyContinue
    Stop-RunnerProcesses
    Clear-Work
}
exit $exitCode
