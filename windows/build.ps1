# Build BattBar for Windows.
#
#   1. build the Rust protocol core as battbar_ffi.dll
#   2. publish the C# tray app as a single self-contained executable
#
# Requires: Rust (with the x86_64-pc-windows-msvc target) and the .NET 8 SDK.
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File windows\build.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$core = Join-Path $root '..\core'
$app = Join-Path $root 'BattBar.Windows\BattBar.Windows.csproj'
$out = Join-Path $root '..\release\win'

Write-Host '==> 构建 Rust 核心（x86_64-pc-windows-msvc）'
cargo build --manifest-path (Join-Path $core 'Cargo.toml') -p battbar-ffi --release --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'Rust 核心构建失败' }

$dll = Join-Path $core 'target\x86_64-pc-windows-msvc\release\battbar_ffi.dll'
if (-not (Test-Path $dll)) { throw "找不到 $dll" }

Write-Host '==> 发布 C# 应用'
dotnet publish $app -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -o $out
if ($LASTEXITCODE -ne 0) { throw 'C# 发布失败' }

Write-Host "==> 完成：$out\BattBar.exe"
Get-ChildItem $out | Select-Object Name, Length
