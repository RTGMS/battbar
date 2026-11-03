# Build BattBar for Windows.
#
#   1. build the Rust protocol core as battbar_ffi.dll
#   2. publish the C# tray app as a single self-contained executable
#
# Requires: Rust and the .NET 8 SDK. The Rust target defaults to the MSVC
# toolchain when a Visual Studio linker is present, and to the self-contained
# GNU toolchain otherwise (no Visual Studio required).
#
# Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File windows\build.ps1
#   powershell -ExecutionPolicy Bypass -File windows\build.ps1 -RustTarget x86_64-pc-windows-gnu

param(
    [string]$RustTarget = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$core = Join-Path $root '..\core'
$app = Join-Path $root 'BattBar.Windows\BattBar.Windows.csproj'
$out = Join-Path $root '..\release\win'

if (-not $RustTarget) {
    $hasMsvc = (Get-Command link.exe -ErrorAction SilentlyContinue) -or
               $env:VSINSTALLDIR -or
               (Test-Path 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe')
    $RustTarget = if ($hasMsvc) { 'x86_64-pc-windows-msvc' } else { 'x86_64-pc-windows-gnu' }
    Write-Host "==> 未指定 -RustTarget，使用 $RustTarget"
}

Write-Host "==> 构建 Rust 核心（$RustTarget）"
cargo build --manifest-path (Join-Path $core 'Cargo.toml') -p battbar-ffi --release --target $RustTarget
if ($LASTEXITCODE -ne 0) { throw 'Rust 核心构建失败' }

$dll = Join-Path $core "target\$RustTarget\release\battbar_ffi.dll"
if (-not (Test-Path $dll)) { throw "找不到 $dll" }

Write-Host '==> 发布 C# 应用'
dotnet publish $app -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -o $out
if ($LASTEXITCODE -ne 0) { throw 'C# 发布失败' }

Write-Host "==> 完成：$out\BattBar.exe"
Get-ChildItem $out | Select-Object Name, Length
