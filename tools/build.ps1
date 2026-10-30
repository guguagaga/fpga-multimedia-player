param([Parameter(Mandatory=$true)][string]$VendorProject,[Parameter(Mandatory=$true)][string]$TdCommand,[string]$Python='python',[int]$Seed=26)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if(([IO.Path]::GetPathRoot($repo)) -ne 'D:\'){throw 'Place the repository on D:'}
$workspace=Join-Path $repo 'build_workspace'
$env:PYTHONUTF8='1'
$env:PYTHONDONTWRITEBYTECODE='1'
$env:TEMP=Join-Path $workspace 'tmp'
$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
& $Python -X utf8 "$PSScriptRoot/assemble_project.py" --vendor-project $VendorProject --out "$workspace/candidate/project"
if($LASTEXITCODE -ne 0){throw 'Project assembly failed'}
New-Item -ItemType Directory -Force "$workspace/tools","$workspace/candidate/scripts","$workspace/reports" | Out-Null
foreach($name in @('build_candidate.ps1','recheck_board_routed.py','audit_clock_scope.py','v167_clock_reference.json','coverage_baseline.json')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path "$workspace/tools" $name) -Force
}
Copy-Item -LiteralPath "$PSScriptRoot/validate_build.py" -Destination "$workspace/candidate/scripts/validate_build.py" -Force
Copy-Item -LiteralPath "$repo/releases/v186/evidence/CONSTRAINT_POLICY.json" -Destination "$workspace/CONSTRAINT_POLICY.json" -Force
& "$workspace/tools/build_candidate.ps1" -Stage All -Seed $Seed -TdCommand $TdCommand -Python $Python -SdSetupMargin 0.6 -VideoSetupMargin 0.2
if($LASTEXITCODE -ne 0){throw 'Candidate build failed'}
& $Python -X utf8 "$workspace/tools/recheck_board_routed.py" $workspace --seed $Seed --td-command $TdCommand
if($LASTEXITCODE -ne 0){throw 'Independent timing/coverage failed'}
