param([Parameter(Mandatory=$true)][string]$VendorProject,[Parameter(Mandatory=$true)][string]$ModelSimDir,[Parameter(Mandatory=$true)][string]$TdSimEg4,[string]$Iverilog='iverilog',[string]$Vvp='vvp')
$ErrorActionPreference='Stop'
$env:PYTHONUTF8='1';$env:MODELSIM_BIN=$ModelSimDir;$env:TD_SIM_EG4=$TdSimEg4;$env:IVERILOG=$Iverilog;$env:VVP=$Vvp
$repo=Split-Path $PSScriptRoot -Parent
$workspace=Join-Path $repo 'build_workspace'
& python -X utf8 "$PSScriptRoot/assemble_project.py" --vendor-project $VendorProject --out "$workspace/candidate/project"
if($LASTEXITCODE -ne 0){throw 'Assembly failed'}
New-Item -ItemType Directory -Force "$workspace/tools","$workspace/tests/templates","$workspace/reports" | Out-Null
Copy-Item -Path "$repo/verification/native720p/run_*.py" -Destination "$workspace/tools" -Force
Copy-Item -Path "$repo/verification/native720p/*.v" -Destination "$workspace/tests" -Force
Copy-Item -LiteralPath "$repo/verification/native720p/templates/av_timeline.v" -Destination "$workspace/tests/templates/av_timeline.v" -Force
foreach($test in @('run_image_center.py','run_display_test.py','run_byte_ram.py','run_packed_test.py','run_concurrent_memory.py','run_long_timeline.py')){
 & python -X utf8 "$workspace/tools/$test"
 if($LASTEXITCODE -ne 0){throw "Regression failed: $test"}
}
