param(
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\windows'),
  [string]$CacheDirectory = (Join-Path $PSScriptRoot '..\artifacts\packaging-input')
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$spec = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-runtime.json') -Raw | ConvertFrom-Json
$destination = [IO.Path]::GetFullPath($OutputDirectory)
$cache = [IO.Path]::GetFullPath($CacheDirectory)
New-Item -ItemType Directory -Force -Path $destination,$cache | Out-Null
$bundle = Join-Path $destination 'BookPocketOpen'
if (Test-Path -LiteralPath $bundle) { throw 'Output bundle already exists; choose a new output directory.' }
$archive = Join-Path $cache "python.$($spec.python.version).zip"
if (!(Test-Path -LiteralPath $archive)) { Invoke-WebRequest -Uri $spec.python.url -OutFile $archive }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $spec.python.sha256) { throw 'Python runtime checksum mismatch' }
$unpacked = Join-Path $cache "python-$($spec.python.version)"
if (!(Test-Path -LiteralPath (Join-Path $unpacked 'tools\python.exe'))) { Expand-Archive -LiteralPath $archive -DestinationPath $unpacked }
New-Item -ItemType Directory -Force -Path $bundle | Out-Null
Copy-Item -LiteralPath (Join-Path $unpacked 'tools') -Destination (Join-Path $bundle 'runtime') -Recurse
$python = Join-Path $bundle 'runtime\python.exe'
& $python -I -m ensurepip --upgrade
if ($LASTEXITCODE) { throw 'Python pip bootstrap failed' }
& $python -I -m pip install --disable-pip-version-check --no-compile --require-hashes -r (Join-Path $repo 'companion\requirements.lock') -r (Join-Path $PSScriptRoot 'build-requirements.lock')
if ($LASTEXITCODE) { throw 'Locked runtime dependency installation failed' }
& $python -I -m pip install --disable-pip-version-check --no-compile --no-deps --no-build-isolation (Join-Path $repo 'companion')
if ($LASTEXITCODE) { throw 'Companion dependency installation failed' }
$packagedVersion = & $python -I -c 'import bookpocket_companion; print(bookpocket_companion.__version__)'
if ($LASTEXITCODE -or $packagedVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid packaged companion version' }
('#define AppVersion "' + $packagedVersion + '"') | Set-Content -LiteralPath (Join-Path $bundle 'installer-version.iss') -Encoding ascii
if (!(Test-Path -LiteralPath (Join-Path $repo 'studio\dist\index.html'))) { throw 'Build studio first' }
Copy-Item -LiteralPath (Join-Path $repo 'studio\dist') -Destination (Join-Path $bundle 'studio') -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows_launcher.py') -Destination (Join-Path $bundle 'launcher.py')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'setup_media.py'),(Join-Path $PSScriptRoot 'windows-runtime.json'),(Join-Path $repo 'LICENSE') -Destination $bundle
if (Test-Path -LiteralPath (Join-Path $repo 'NOTICE')) { Copy-Item -LiteralPath (Join-Path $repo 'NOTICE') -Destination $bundle }
# Remove local wheel origin metadata; never ship a developer's source path.
Get-ChildItem -LiteralPath (Join-Path $bundle 'runtime\Lib\site-packages') -Filter direct_url.json -Recurse -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
@'
@echo off
"%~dp0runtime\python.exe" -I "%~dp0setup_media.py" --destination "%~dp0tools"
if errorlevel 1 (echo Installation failed. Check your connection and retry. & pause & exit /b 1)
echo Setup complete. Open Book Pocket Open.vbs to launch the studio.
pause
'@ | Set-Content -LiteralPath (Join-Path $bundle 'Setup Media.cmd') -Encoding ascii
@'
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run """" & root & "\runtime\pythonw.exe"" -I """ & root & "\launcher.py""", 0, False
'@ | Set-Content -LiteralPath (Join-Path $bundle 'Book Pocket Open.vbs') -Encoding ascii
@'
Book Pocket Open for Windows x64 - unsigned preview

Portable setup: run Setup Media.cmd once to download checksum-verified FFmpeg directly from its upstream publisher. Then open Book Pocket Open.vbs. The installer performs media setup automatically. Setup and optional speech-model installation require internet.

No existing Python, Node.js, Git, or developer tools are required. Personal books, voices, models, certificates and settings are stored under your Windows local app data outside the application folder. Uninstalling preserves that personal data.

Python source and license: windows-runtime.json and runtime/LICENSE.txt. Package license notices remain in runtime/Lib/site-packages/*.dist-info. FFmpeg is downloaded separately from upstream; its LGPL license and exact provenance are saved in tools after setup. Engines and model weights are optional downloads with licenses displayed in the studio.

This release is not code-signed. Windows may show an unrecognized publisher. Verify the published SHA256 before installing.
'@ | Set-Content -LiteralPath (Join-Path $bundle 'WINDOWS-README.txt') -Encoding utf8
& $python -I -c 'import importlib.metadata,json,pathlib,sys; rows=[{"name":d.metadata["Name"],"version":d.version,"license":d.metadata.get("License-Expression") or d.metadata.get("License","")} for d in importlib.metadata.distributions()]; pathlib.Path(sys.argv[1]).write_text(json.dumps(sorted(rows,key=lambda r:r["name"].lower()),indent=2),encoding="utf-8")' (Join-Path $bundle 'python-packages.json')
if ($LASTEXITCODE) { throw 'Package inventory failed' }
$zip = Join-Path $destination 'BookPocketOpen-Windows-x64.zip'
Compress-Archive -LiteralPath $bundle -DestinationPath $zip
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($zip))" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
Write-Output "Portable package: $zip"


