// AI-assisted; see NOTICE.md
// Tang Nano 20K - 1080p30 变体的时序约束
// Tang Nano 20K - 1080p30 variant timing constraints
// 371.25 MHz TMDS 位时钟，74.25 MHz 像素时钟（CLKDIV /5）
// 371.25 MHz TMDS bit clock, 74.25 MHz pixel clock (CLKDIV /5)

create_clock -name clk27  -period 37.037 [get_ports {sys_clk}]
create_clock -name clk5   -period 2.6936 [get_nets {clk5}]
create_clock -name clkpix -period 13.468 [get_nets {clkpix}]
