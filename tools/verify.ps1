param([string]$VendorProject,[Parameter(Mandatory=$true)][string]$ModelSimDir,[string]$Python='python')
$ErrorActionPreference='Stop'
$env:MODELSIM_BIN=$ModelSimDir
$repo=Split-Path $PSScriptRoot -Parent
if (-not $VendorProject) { $VendorProject=Join-Path $repo 'vendor_original' }
$env:PYTHONUTF8='1'
$env:PYTHONDONTWRITEBYTECODE='1'
$env:TEMP=Join-Path $repo 'build_workspace/tmp'
$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
$workspace=Join-Path $repo 'build_workspace'
& $Python "$PSScriptRoot/assemble_project.py" --vendor-project $VendorProject --out "$workspace/candidate/project"
if($LASTEXITCODE -ne 0){throw 'Project assembly failed'}
Copy-Item -Path "$repo/verification/*" -Destination $workspace -Recurse -Force
& $Python "$workspace/tools/run_sd_speed_validation.py" --modelsim-dir $ModelSimDir
if($LASTEXITCODE -ne 0){throw 'SD regression failed'}
& $Python "$workspace/tools/run_image_validation.py" --modelsim-dir $ModelSimDir --workers 2
if($LASTEXITCODE -ne 0){throw 'Image regression failed'}

& $Python "$workspace/tools/run_fast_cache.py"
if($LASTEXITCODE -ne 0){throw 'Production image cache regression failed'}
