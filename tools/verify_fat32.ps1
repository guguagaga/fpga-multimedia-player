param([string]$VendorProject,[string]$Iverilog='iverilog',[string]$Vvp='vvp',[string]$Python='python')
$ErrorActionPreference='Stop';$env:PYTHONUTF8='1';$env:IVERILOG=$Iverilog;$env:VVP=$Vvp
$repo=Split-Path $PSScriptRoot -Parent
if (-not $VendorProject) { $VendorProject=Join-Path $repo 'vendor_original' }
$env:PYTHONUTF8='1'
$env:PYTHONDONTWRITEBYTECODE='1'
$env:TEMP=Join-Path $repo 'build_workspace/tmp'
$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
$release=(Get-Content -LiteralPath "$repo/project_manifest.json" -Raw | ConvertFrom-Json).release
$work=Join-Path (Join-Path $repo 'fat32_verification_workspace') $release
& $Python -X utf8 "$PSScriptRoot/assemble_project.py" --vendor-project $VendorProject --out "$work/candidate/project"
if($LASTEXITCODE -ne 0){throw 'Assembly failed'}
New-Item -ItemType Directory -Force "$work/tests","$work/reports" | Out-Null
Copy-Item -LiteralPath "$repo/verification/fat32/tb_mapper.v","$repo/verification/fat32/spectrum_reference_source.v" -Destination "$work/tests" -Force
Copy-Item -LiteralPath "$repo/verification/fat32/run_tests.py","$repo/verification/fat32/test_spectrum_equivalence.py" -Destination $work -Force
Copy-Item -LiteralPath "$repo/verification/fat32/test_directory.py" -Destination "$work/tests" -Force
foreach($test in @('run_tests.py','tests/test_directory.py','test_spectrum_equivalence.py')){
 & $Python -X utf8 "$work/$test"
 if($LASTEXITCODE -ne 0){throw "Regression failed: $test"}
}
