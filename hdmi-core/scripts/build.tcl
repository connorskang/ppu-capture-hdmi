# AI-assisted; see NOTICE.md
# gw_sh 的 TCL 构建脚本。
# gw_sh TCL build script.
# 必须在当前目录 == 存放 .gprj 的目录时运行；工程文件里的所有路径都是
# 相对路径，因此永远不会编码出非 ASCII 路径。
# Must run with CWD == the directory holding the .gprj; all project file paths
# are relative so no non-ASCII path is ever encoded.
#
# 用法：gw_sh.exe build.tcl <syn|pnr|all> [project.gprj]
# usage: gw_sh.exe build.tcl <syn|pnr|all> [project.gprj]
if {$argc < 1} {
    puts "USAGE: gw_sh.exe build.tcl \[syn|pnr|all\] \[project.gprj\]"
    exit 1
}
set task [lindex $argv 0]
set proj "tn20k_hdmi1080p.gprj"
if {$argc >= 2} { set proj [lindex $argv 1] }

if {[catch {open_project $proj} e]} {
    puts "########## BUILD FAILED: open_project -> $e"
    exit 1
}
puts "open_project OK ($proj)"

if {[catch {run $task} e]} {
    puts "########## BUILD FAILED: run $task -> $e"
    exit 1
}
puts "########## BUILD SCRIPT FINISHED ($task)"
exit 0
