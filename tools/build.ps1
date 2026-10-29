param([Parameter(Mandatory=$true)][string]$VendorProject,[Parameter(Mandatory=$true)][string]$TdCommand,[int]$Seed=26)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$workspace=Join-Path $repo 'build_workspace'
& python "$PSScriptRoot/assemble_project.py" --vendor-project $VendorProject --out "$workspace/candidate/project"
if($LASTEXITCODE -ne 0){throw 'Project assembly failed'}
New-Item -ItemType Directory -Force "$workspace/tools","$workspace/candidate/scripts" | Out-Null
New-Item -ItemType Directory -Force "$workspace/reports" | Out-Null
Copy-Item -LiteralPath "$PSScriptRoot/build_candidate.ps1" -Destination "$workspace/tools/build_candidate.ps1" -Force
Copy-Item -LiteralPath "$PSScriptRoot/validate_build.py" -Destination "$workspace/candidate/scripts/validate_build.py" -Force
& "$workspace/tools/build_candidate.ps1" -Stage All -Seed $Seed -TdCommand $TdCommand
if($LASTEXITCODE -ne 0){throw 'Candidate build failed'}
foreach($name in @('recheck_board_routed.py','audit_clock_scope.py','v167_clock_reference.json')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path "$workspace/tools" $name) -Force
}
& python "$workspace/tools/recheck_board_routed.py" $workspace --seed $Seed --td-command $TdCommand
if($LASTEXITCODE -ne 0){throw 'Independent routed timing check failed'}
