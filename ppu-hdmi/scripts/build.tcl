# AI-assisted; see NOTICE.md
# gw_sh 的 TCL 构建脚本。
# gw_sh TCL build script.
# 必须在当前目录 == 存放 .gprj 的目录时运行；工程文件里的所有路径都是
# 相对路径，因此永远不会编码出非 ASCII 路径。
# Must run with CWD == the directory holding the .gprj; all project file paths
# are relative so no non-ASCII path is ever encoded.
#
# 用法：gw_sh.exe build.tcl <syn|pnr|all> [project.gprj] [place_opt] [route_opt] [timing_driven]
# usage: gw_sh.exe build.tcl <syn|pnr|all> [project.gprj] [place_opt] [route_opt] [timing_driven]
if {$argc < 1} {
    puts "USAGE: gw_sh.exe build.tcl \[syn|pnr|all\] \[project.gprj\] \[place_opt\] \[route_opt\] \[timing_driven\]"
    exit 1
}
set task [lindex $argv 0]
set proj "ppu_hdmi.gprj"
if {$argc >= 2} { set proj [lindex $argv 1] }

if {[catch {open_project $proj} e]} {
    puts "########## BUILD FAILED: open_project -> $e"
    exit 1
}
puts "open_project OK ($proj)"

# 布局 / 布线努力等级。默认值（place_option 0、route_option 0）在第一次构建时
# 让 11 个像素域端点差一点没跑到 74.25 MHz，所以封装脚本可以提高努力等级并
# 打开时序驱动布局。
# Placement / routing effort.  The default (place_option 0, route_option 0)
# left 11 pixel-domain endpoints short of 74.25 MHz on the first build, so the
# wrapper can raise the effort and turn on timing-driven placement.
if {$argc >= 3} {
    set po [lindex $argv 2]
    if {[catch {set_option -place_option $po} e]} {
        puts "########## set_option -place_option failed: $e"
    } else { puts "set_option -place_option $po" }
}
if {$argc >= 4} {
    set ro [lindex $argv 3]
    if {[catch {set_option -route_option $ro} e]} {
        puts "########## set_option -route_option failed: $e"
    } else { puts "set_option -route_option $ro" }
}
if {$argc >= 5} {
    set td [lindex $argv 4]
    if {[catch {set_option -timing_driven $td} e]} {
        puts "########## set_option -timing_driven failed: $e"
    } else { puts "set_option -timing_driven $td" }
}

# 额外的开关，全部可选（传 "-" 表示跳过）：
# Extra knobs, all optional (pass "-" to skip):
#   argv 5 : -global_freq      （MHz；工具默认 100）/ (MHz; tool default is 100)
#   argv 6 : -correct_hold_violation  (0/1)
#   argv 7 : -replicate_resources     (0/1)
foreach {idx opt} {5 -global_freq 6 -correct_hold_violation 7 -replicate_resources} {
    if {$argc > $idx} {
        set v [lindex $argv $idx]
        if {$v ne "-"} {
            if {[catch {set_option $opt $v} e]} {
                puts "########## set_option $opt $v failed: $e"
            } else { puts "set_option $opt $v" }
        }
    }
}

if {[catch {run $task} e]} {
    puts "########## BUILD FAILED: run $task -> $e"
    exit 1
}
puts "########## BUILD SCRIPT FINISHED ($task)"
exit 0
