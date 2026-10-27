param([Parameter(Mandatory=$true)][string]$VendorProject,[Parameter(Mandatory=$true)][string]$TdCommand,[int]$Seed=18)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$workspace=Join-Path $repo 'build_workspace'
& python "$PSScriptRoot/assemble_project.py" --vendor-project $VendorProject --out "$workspace/candidate/project"
if($LASTEXITCODE -ne 0){throw 'Project assembly failed'}
New-Item -ItemType Directory -Force "$workspace/tools","$workspace/candidate/scripts" | Out-Null
Copy-Item -LiteralPath "$PSScriptRoot/build_candidate.ps1" -Destination "$workspace/tools/build_candidate.ps1" -Force
Copy-Item -LiteralPath "$PSScriptRoot/validate_build.py" -Destination "$workspace/candidate/scripts/validate_build.py" -Force
& "$workspace/tools/build_candidate.ps1" -Stage All -Seed $Seed -TdCommand $TdCommand
