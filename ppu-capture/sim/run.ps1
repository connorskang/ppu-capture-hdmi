# AI-assisted; see NOTICE.md
# SPDX-License-Identifier: GPL-3.0-or-later
# -----------------------------------------------------------------------------
# run.ps1 - 编译并运行 PPU 采集转接板的仿真。
# run.ps1 - build and run the PPU capture interposer simulation.
#
# 工作区路径含有非 ASCII 字符，因此所有源码在调用 Icarus Verilog 之前都会被
# 复制到一个 ASCII 临时目录。
# The workspace path contains non-ASCII characters, so all sources are copied
# into an ASCII temp directory before invoking Icarus Verilog.
#
# 用法（本机执行策略为 Restricted）：
# Usage (execution policy is Restricted on this host):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run.ps1
#
# 主运行使用 EXT_OUT_BIT=6，即有文档依据的 2C02 EXT 方向位。
# 任务书原版的 EXT_OUT_BIT=2 变体只在带 -RunBit2 时运行；预期它会通不过
# 调色板测试，因为强制 bit 2 会改变 VRAM 增量并破坏 +1/+32 行为。
# The primary run uses EXT_OUT_BIT=6, the documented 2C02 EXT-direction bit.
# The legacy task-statement EXT_OUT_BIT=2 variant is only run with -RunBit2;
# it is expected to fail the palette tests because forcing bit 2 changes the
# VRAM increment and corrupts the +1/+32 behaviour.
# -----------------------------------------------------------------------------
param(
    [switch]$RunBit2
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$tmp  = Join-Path $env:TEMP ("ppu-intercept-sim-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

$iverilog = "C:\iverilog\bin\iverilog.exe"
$vvp      = "C:\iverilog\bin\vvp.exe"

if (!(Test-Path $iverilog)) { throw "iverilog not found at $iverilog" }
if (!(Test-Path $vvp))      { throw "vvp not found at $vvp" }

New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Copy-Item (Join-Path $root "rtl\*.v") $tmp
Copy-Item (Join-Path $root "tb\*.v")  $tmp

$src = @(
    "ppu_write_guard.v",
    "ppu_injector.v",
    "ppu_palette_shadow.v",
    "ppu_ext_capture.v",
    "ppu_pixel_out.v",
    "ppu_capture_intercept.v",
    "tb_ppu_intercept.v"
)

Push-Location $tmp
try {
    Write-Host "== 编译 EXT_OUT_BIT=6（有文档依据的 2C02 EXT 方向位）/ Building EXT_OUT_BIT=6 (documented 2C02 EXT-direction bit) =="
    & $iverilog -g2005 -Wall -o simv6 @src
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed for EXT_OUT_BIT=6" }

    Write-Host "== 运行 EXT_OUT_BIT=6 / Running EXT_OUT_BIT=6 =="
    & $vvp simv6 2>&1 | Tee-Object -FilePath "run_EXT_OUT_BIT6.log"
    if ($LASTEXITCODE -ne 0) { throw "vvp failed for EXT_OUT_BIT=6" }

    Copy-Item "run_EXT_OUT_BIT6.log" (Join-Path $root "sim\simulation_output_bit6.txt") -Force
    Copy-Item "ppu_intercept.vcd"  (Join-Path $root "sim\ppu_intercept_bit6.vcd") -Force

    if ($RunBit2) {
        Write-Host ""
        Write-Host "== 编译 EXT_OUT_BIT=2（任务书旧变体）/ Building EXT_OUT_BIT=2 (legacy task-statement variant) =="
        & $iverilog -g2005 -Wall -P tb_ppu_intercept.EXT_OUT_BIT=2 -o simv2 @src
        if ($LASTEXITCODE -ne 0) { throw "iverilog failed for EXT_OUT_BIT=2" }

        Write-Host "== 运行 EXT_OUT_BIT=2 / Running EXT_OUT_BIT=2 =="
        & $vvp simv2 2>&1 | Tee-Object -FilePath "run_EXT_OUT_BIT2.log"
        if ($LASTEXITCODE -ne 0) { throw "vvp failed for EXT_OUT_BIT=2" }

        Copy-Item "run_EXT_OUT_BIT2.log" (Join-Path $root "sim\simulation_output_bit2.txt") -Force
        Copy-Item "ppu_intercept.vcd"  (Join-Path $root "sim\ppu_intercept_bit2.vcd") -Force
    }

    Write-Host ""
    Write-Host "产物写到 / Artifacts written under $root\sim"
    Write-Host "  simulation_output_bit6.txt, ppu_intercept_bit6.vcd (primary)"
    if ($RunBit2) {
        Write-Host "  simulation_output_bit2.txt, ppu_intercept_bit2.vcd (legacy comparison)"
    }
} finally {
    Pop-Location
    # 失败时保留临时目录便于调试；成功时删除。
    # Keep the temp directory on failure for debugging; delete it on success.
    if ($LASTEXITCODE -eq 0) {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    } else {
        Write-Host "Temp build directory kept: $tmp"
    }
}
