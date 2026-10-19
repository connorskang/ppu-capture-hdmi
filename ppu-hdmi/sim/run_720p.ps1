# AI-assisted; see NOTICE.md
# SPDX-License-Identifier: GPL-3.0-or-later
# -----------------------------------------------------------------------------
# run_720p.ps1 - 编译并运行 PPU -> HDMI（720p60）集成仿真。
# run_720p.ps1 - build and run the 720p60 integrated PPU -> HDMI simulation.
#
# 与 run.ps1 的区别只有两处：换成 tb_ppu_hdmi_720p.v 和
# ppu_video_pipeline_720p.v。两个仿真互不影响，1080p30 的那份仍然原样可跑。
# 工作区路径含有非 ASCII 字符，因此所有源码在调用 Icarus Verilog 之前都会被
# 复制到一个 ASCII 临时目录。
# Only two things differ from run.ps1: tb_ppu_hdmi_720p.v and
# ppu_video_pipeline_720p.v.  The two simulations are independent; the 1080p30
# one still runs unchanged.
# The workspace path contains non-ASCII characters, so all sources are copied
# into an ASCII temp directory before invoking Icarus Verilog.
#
# 用法（本机执行策略为 Restricted，且未安装 pwsh）：
# Usage (this host's execution policy is Restricted, and pwsh is not installed):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_720p.ps1
#   ... -File .\sim\run_720p.ps1 -Vcd     # 同时写出 ppu_hdmi_720p.vcd
# -----------------------------------------------------------------------------
param(
    [switch]$Vcd
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$tmp  = Join-Path $env:TEMP ("ppu-hdmi-720p-sim-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

$iverilog = "C:\iverilog\bin\iverilog.exe"
$vvp      = "C:\iverilog\bin\vvp.exe"

if (!(Test-Path $iverilog)) { throw "iverilog not found at $iverilog" }
if (!(Test-Path $vvp))      { throw "vvp not found at $vvp" }

New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Copy-Item (Join-Path $root "rtl\*.v") $tmp
Copy-Item (Join-Path $root "tb\*.v")  $tmp

$src = @(
    "hdmi_timing.v",
    "tmds_encoder.v",
    "nes_palette.v",
    "ppu_framebuffer.v",
    "ppu_write_guard.v",
    "ppu_injector.v",
    "ppu_palette_shadow.v",
    "ppu_ext_capture.v",
    "ppu_pixel_out.v",
    "ppu_capture_intercept.v",
    "ppu_video_pipeline_720p.v",
    "tb_ppu_hdmi_720p.v"
)

Push-Location $tmp
try {
    Write-Host "== iverilog（Verilog-2001）/ iverilog (Verilog-2001) =="
    & $iverilog -g2005 -o simv720 @src
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed" }

    Write-Host "== vvp =="
    $vvpArgs = @("simv720")
    if ($Vcd) { $vvpArgs += "+vcd" }
    & $vvp @vvpArgs 2>&1 | Tee-Object -FilePath "run.log"

    Copy-Item "run.log" (Join-Path $root "sim\simulation_output_720p.txt") -Force
    if ($Vcd -and (Test-Path "ppu_hdmi_720p.vcd")) {
        Copy-Item "ppu_hdmi_720p.vcd" (Join-Path $root "sim\ppu_hdmi_720p.vcd") -Force
    }
    Write-Host ""
    Write-Host "产物写到 / Artifacts written under $root\sim"
} finally {
    Pop-Location
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
