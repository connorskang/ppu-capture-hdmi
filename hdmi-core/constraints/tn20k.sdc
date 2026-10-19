// AI-assisted; see NOTICE.md
// Tang Nano 20K 1080p60 HDMI - 时序约束
// Tang Nano 20K 1080p60 HDMI - timing constraints
//
// 27 MHz 参考时钟 / 27 MHz reference
create_clock -name clk27  -period 37.037 [get_ports {sys_clk}]
//
// 742.5 MHz TMDS 位时钟（OSER10 FCLK）   T = 1.34680 ns
// 742.5 MHz  TMDS bit clock (OSER10 FCLK)   T = 1.34680 ns
create_clock -name clk5   -period 1.3468  [get_nets {clk5}]
//
// 148.5 MHz 像素时钟（OSER10 PCLK）     T = 6.73401 ns
// 148.5 MHz  pixel clock (OSER10 PCLK)     T = 6.73401 ns
create_clock -name clkpix -period 6.7340  [get_nets {clkpix}]
