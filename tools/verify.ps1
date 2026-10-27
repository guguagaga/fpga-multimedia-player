param([Parameter(Mandatory=$true)][string]$VendorProject,[Parameter(Mandatory=$true)][string]$ModelSimDir)
$ErrorActionPreference='Stop'
$env:MODELSIM_BIN=$ModelSimDir
$repo=Split-Path $PSScriptRoot -Parent
$workspace=Join-Path $repo 'build_workspace'
& python "$PSScriptRoot/assemble_project.py" --vendor-project $VendorProject --out "$workspace/candidate/project"
if($LASTEXITCODE -ne 0){throw 'Project assembly failed'}
Copy-Item -Path "$repo/verification/*" -Destination $workspace -Recurse -Force
& python "$workspace/tools/run_sd_speed_validation.py" --modelsim-dir $ModelSimDir
if($LASTEXITCODE -ne 0){throw 'SD regression failed'}
& python "$workspace/tools/run_image_validation.py" --modelsim-dir $ModelSimDir --workers 2
if($LASTEXITCODE -ne 0){throw 'Image regression failed'}

& python "$workspace/tools/run_fast_cache.py"
if($LASTEXITCODE -ne 0){throw 'Production image cache regression failed'}
