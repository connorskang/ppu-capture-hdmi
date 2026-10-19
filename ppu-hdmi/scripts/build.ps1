# AI-assisted; see NOTICE.md
# PPU -> HDMI 集成工程的构建封装脚本。
# Build wrapper for the integrated PPU -> HDMI project.
#
# 工具链：默认为已授权的标准安装 V1.9.12（许可证注册在
# <root>\IDE\bin\gwlicense.ini）；可用 -GowinRoot 覆盖，例如更早的
# Education 版 C:\Gowin\Gowin_V1.9.11.03_Education_x64（无需许可证）。
# Toolchain: defaults to the licensed standard install V1.9.12 (license registered
# in <root>\IDE\bin\gwlicense.ini); override with -GowinRoot, e.g. the older
# Education build C:\Gowin\Gowin_V1.9.11.03_Education_x64 which needs no license.
#
# 为什么要这个脚本：高云命令行（gw_sh.exe）无法处理含非 ASCII 字符的工程路径。
# 本工作区位于 "...\OneDrive\文档\..."，gw_sh 会把它搞成 "??"，于是报：
#   ERROR (SP0002) : Corrupted project file: ".../OneDrive/??/.../impl/gwsynthesis/*.prj"
# 解决办法（与 hdmi-core/scripts/build.ps1 相同）：把源码镜像到一个 ASCII
# 临时目录，在那里构建，再把 impl/ 拷回来。
# WHY THIS EXISTS: the Gowin CLI (gw_sh.exe) cannot handle a project path
# containing non-ASCII characters.  This workspace lives under
# "...\OneDrive\文档\..." and gw_sh mangles that to "??", producing
#   ERROR (SP0002) : Corrupted project file: ".../OneDrive/??/.../impl/gwsynthesis/*.prj"
# Workaround (same as hdmi-core/scripts/build.ps1): mirror the sources
# into an ASCII scratch directory, build there, copy impl/ back.
#
# 用法（本机执行策略为 Restricted，且未安装 pwsh）：
# Usage (this host's execution policy is Restricted, pwsh is not installed):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1

param(
    # V1.9.12（已授权的标准安装），2026-10-18 从 Education 版切换过来；
    # 许可证位于 <root>\IDE\bin\gwlicense.ini。保持可覆盖。
    # V1.9.12 (licensed standard install), switched from the Education build on
    # 2026-10-18; license lives in <root>\IDE\bin\gwlicense.ini. Keep overridable.
    [string]$GowinRoot = "C:\Gowin\Gowin_V1.9.12_x64",
    [ValidateSet("syn","pnr","all")][string]$Task = "all",
    [string]$Project = "ppu_hdmi.gprj",
    [string]$PlaceOption = "0",
    [string]$RouteOption = "0",
    [string]$TimingDriven = "0",
    [string]$GlobalFreq = "-",
    [string]$CorrectHold = "-",
    [string]$Replicate = "-",
    [switch]$CleanImpl
)

$ErrorActionPreference = "Stop"
$proj  = Split-Path -Parent $PSScriptRoot          # ...\ppu-hdmi
$stem  = [System.IO.Path]::GetFileNameWithoutExtension($Project)
$work  = Join-Path $env:TEMP ("ppu_hdmi_build_" + $stem)

Write-Host "project : $proj"
Write-Host "gprj    : $Project"
Write-Host "scratch : $work"
Write-Host "gowin   : $GowinRoot"

if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null

foreach ($d in @("rtl","constraints")) {
    Copy-Item (Join-Path $proj $d) (Join-Path $work $d) -Recurse -Force
}
Get-ChildItem $proj -Filter *.gprj | Copy-Item -Destination $work -Force
Copy-Item (Join-Path $proj "scripts\build.tcl") $work -Force

$env:GOWIN_HOME = $GowinRoot
$gwsh = Join-Path $GowinRoot "IDE\bin\gw_sh.exe"
if (-not (Test-Path $gwsh)) { throw "gw_sh.exe not found at $gwsh" }

$ErrorActionPreference = "Continue"
$outLog = Join-Path $work "gw_sh.out.txt"
$errLog = Join-Path $work "gw_sh.err.txt"

Push-Location $work
try {
    & $gwsh "build.tcl" $Task $Project $PlaceOption $RouteOption $TimingDriven $GlobalFreq $CorrectHold $Replicate > $outLog 2> $errLog
    $code = $LASTEXITCODE
}
finally { Pop-Location }

Write-Host "----- gw_sh stdout -----"
if (Test-Path $outLog) { Get-Content $outLog }
Write-Host "----- gw_sh stderr (alog noise expected) -----"
if (Test-Path $errLog) { Get-Content $errLog }

Write-Host "`n===== gw_sh exit code: $code ====="

$implSrc = Join-Path $work "impl"
if (Test-Path $implSrc) {
    $implDst = Join-Path $proj "impl"
    if ($CleanImpl -and (Test-Path $implDst)) { Remove-Item $implDst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $implDst | Out-Null
    Copy-Item (Join-Path $implSrc "*") $implDst -Recurse -Force
    Write-Host "impl/ copied back to $implDst"
}

$fs = Get-ChildItem $work -Recurse -Filter *.fs -ErrorAction SilentlyContinue
if ($fs) {
    Write-Host "`nBITSTREAM(S):"
    $fs | ForEach-Object { Write-Host ("  {0}  ({1:N0} bytes)" -f $_.FullName, $_.Length) }
} else {
    Write-Host "`nNO .fs PRODUCED -> build did not succeed."
}

exit $code
