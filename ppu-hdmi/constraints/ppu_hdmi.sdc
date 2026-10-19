// AI-assisted; see NOTICE.md
// PPU 采集 -> HDMI 集成，1080p30（1920x1080 @ 74.25 MHz）
// Integrated PPU capture -> HDMI, 1080p30 (1920x1080 @ 74.25 MHz)
//
// clk27   : 板上 27 MHz 晶振 / 27 MHz board oscillator
// clk5    : 371.25 MHz rPLL 输出 -> OSER10 FCLK（TMDS 位时钟）
// clk5    : 371.25 MHz rPLL output -> OSER10 FCLK (TMDS bit clock)
// clkpix  : 74.25 MHz CLKDIV /5   -> 像素域（视频流水线）
// clkpix  : 74.25 MHz CLKDIV /5   -> pixel domain (video pipeline)
// ppupix  : 5.369 MHz 2C02 点时钟（21.47727 MHz / 4）-> 采集域
// ppupix  : 5.369 MHz 2C02 dot clock (21.47727 MHz / 4) -> capture domain
//
// 注意：与父工程一样，STA 对 clk5 报告 "no timing paths"，因为它只连到
// OSER10 硬核的 FCLK 引脚。这是预期现象，*不*能作为 371.25 MHz 可用的证据；
// 那里的限制是 PLL 规格（CLKOUT <= 625 MHz，371.25 比它低 41%）。
// NOTE: as in the parent project, STA reports "no timing paths" for clk5
// because it only reaches OSER10 hard-macro FCLK pins.  That is expected and
// is NOT evidence that 371.25 MHz works; the limit there is the PLL spec
// (CLKOUT <= 625 MHz, 371.25 is 41 % below it).

create_clock -name clk27  -period 37.037 [get_ports {sys_clk}]
create_clock -name clk5   -period 2.6936 [get_nets {clk5}]
create_clock -name clkpix -period 13.468 [get_nets {clkpix}]
create_clock -name ppupix -period 186.24 [get_ports {ppu_pix_clk}]
