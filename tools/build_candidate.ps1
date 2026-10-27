param(
    [ValidateSet('All','Synthesis','Physical')][string]$Stage='All',
    [int]$Seed=12,
    [string]$TdCommand=$env:CODEC9_TD_CMD,
    [string]$Python='python'
)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$projectRoot=Join-Path $taskRoot 'candidate\project'
$runRoot=Join-Path $projectRoot 'td_project\HDMI1.4b_Transmitter_v1.0_Runs'
$reportRoot=Join-Path $taskRoot 'candidate\reports'
$env:PYTHONUTF8='1'
$Python=(Get-Command $Python -ErrorAction Stop).Source
if (-not $TdCommand) {
    $found=Get-Command td_commands_prompt.exe -ErrorAction SilentlyContinue
    if ($found) { $TdCommand=$found.Source }
}
if (-not $TdCommand -or -not (Test-Path -LiteralPath $TdCommand -PathType Leaf)) {
    throw 'Supply -TdCommand with the full path to td_commands_prompt.exe, or set CODEC9_TD_CMD.'
}
$TdCommand=(Resolve-Path -LiteralPath $TdCommand).Path
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null

function Invoke-Python {
    param([string[]]$Arguments)
    & $Python @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Python step failed: $($Arguments[0])" }
}
function Get-SourceSnapshot {
    $snapshot=@{}
    Get-ChildItem -LiteralPath $projectRoot -Recurse -File | ForEach-Object {
        if ($_.FullName -notmatch '_Runs' -and $_.Extension.ToLowerInvariant() -in @('.v','.sdc','.adc','.al','.mem','.hex')) {
            $rel=$_.FullName.Substring($projectRoot.Length+1).Replace('\','/')
            $snapshot[$rel]=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return $snapshot
}
$synthesisRecord=Join-Path $reportRoot 'cjk_align_synthesis.json'
$gate=Join-Path $runRoot 'syn_1\HDMI1.4b_Transmitter_v1.0_gate.db'
if ($Stage -in @('All','Synthesis')) {
    $runDir=Join-Path $runRoot 'syn_1'
    $started=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $snapshot=Get-SourceSnapshot
    Invoke-Python -Arguments @("$projectRoot\build\_mk_prj2.py",$runDir)
    Copy-Item -LiteralPath "$projectRoot\build\settings_syn_1.cfg" -Destination "$runDir\settings.cfg" -Force
    Copy-Item -LiteralPath "$projectRoot\build\phy_stage_flow.tcl" -Destination "$runDir\local_flow.tcl" -Force
    & cmd.exe /d /c "`"$projectRoot\build\_flow_run.cmd`" `"$runDir`" `"local_flow.tcl`" `"$TdCommand`""
    if ($LASTEXITCODE -ne 0) { throw 'Synthesis failed' }
    $flow=Get-Content -LiteralPath "$runDir\flow_stdout.txt" -Raw
    if ($flow -notmatch 'TD_FLOW_FINISHED' -or $flow -notmatch 'FLOW_EXIT=0' -or $flow -match '\bERROR:|TD_FLOW_FAILED') {
        throw 'Synthesis log validation failed'
    }
    $gateItem=Get-Item -LiteralPath $gate
    if (([DateTimeOffset]$gateItem.LastWriteTimeUtc).ToUnixTimeSeconds() -lt $started) { throw 'Stale synthesis database' }
    $after=Get-SourceSnapshot
    if ($after.Count -ne $snapshot.Count) { throw 'Source set changed during synthesis' }
    foreach ($key in $snapshot.Keys) {
        if ($after[$key] -ne $snapshot[$key]) { throw "Source changed during synthesis: $key" }
    }
    @{started_unix=$started; sources=$snapshot; gate_sha256=(Get-FileHash -LiteralPath $gate -Algorithm SHA256).Hash.ToLowerInvariant()} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $synthesisRecord -Encoding utf8
    Write-Output "PASS fresh synthesis database: $gate"
}
if ($Stage -in @('All','Physical')) {
    if (-not (Test-Path -LiteralPath $synthesisRecord)) { throw 'Run -Stage Synthesis first' }
    $syn=Get-Content -LiteralPath $synthesisRecord -Raw | ConvertFrom-Json
    $now=Get-SourceSnapshot
    $entries=@($syn.sources.PSObject.Properties)
    if ($entries.Count -ne $now.Count) { throw 'Source set changed since synthesis' }
    foreach ($entry in $entries) {
        if ($now[$entry.Name] -ne $entry.Value) { throw "Source changed since synthesis: $($entry.Name)" }
    }
    if ((Get-FileHash -LiteralPath $gate -Algorithm SHA256).Hash.ToLowerInvariant() -ne $syn.gate_sha256) {
        throw 'Synthesis database changed; run -Stage Synthesis again'
    }
    $runDir=Join-Path $runRoot "phy_cjk_align_seed$Seed"
    $reportDir=Join-Path $reportRoot "cjk_align_seed$Seed"
    New-Item -ItemType Directory -Path $runDir,$reportDir -Force | Out-Null
    Invoke-Python -Arguments @("$projectRoot\build\_mk_prj2.py",$runDir)
    Copy-Item -LiteralPath "$projectRoot\build\settings_phy_1.cfg" -Destination "$runDir\settings.cfg" -Force
    $flow=Get-Content -LiteralPath "$projectRoot\build\phy_stage_flow.tcl" -Raw
    if (-not $flow.Contains('set_param place effort high')) { throw 'Unexpected physical flow script' }
    $flow=$flow.Replace('set_param place effort high',"set_param place effort high`n  set_param flow enable_seed on`n  set_param place seed $Seed")
    $flowPath=Join-Path $reportDir 'physical_flow.tcl'
    # Windows PowerShell 5.1 adds a BOM with -Encoding utf8; TD's Tcl
    # interpreter treats those bytes as part of the first command.
    [System.IO.File]::WriteAllText($flowPath,$flow,[System.Text.UTF8Encoding]::new($false))
    $started=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    @{seed=$Seed;started_unix=$started;run_dir=$runDir;synthesis=$syn} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$reportDir\run.json" -Encoding utf8
    Copy-Item -LiteralPath $flowPath -Destination "$runDir\local_flow.tcl" -Force
    & cmd.exe /d /c "`"$projectRoot\build\_flow_run.cmd`" `"$runDir`" `"local_flow.tcl`" `"$TdCommand`""
    if ($LASTEXITCODE -ne 0) { throw 'TD physical run failed' }
    Invoke-Python -Arguments @("$taskRoot\candidate\scripts\validate_build.py",'--since',"$started",'--run-dir',$runDir,'--report',"$reportDir\build_validation.json")
    Write-Output "Validated output: $runDir\HDMI1.4b_Transmitter_v1.0.bit"
}
