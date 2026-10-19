// AI-assisted; see NOTICE.md
// 27 MHz -> 742.5 MHz（5 倍像素时钟）+ 148.5 MHz（像素时钟）
// 27 MHz -> 742.5 MHz (5x pixel clock) + 148.5 MHz (pixel clock)
// 高云 rPLL 原语实例化（见高云《Primitive User Guide》SUG283）。
// Gowin rPLL primitive instantiation (Gowin "Primitive User Guide" SUG283).
//
// 计算：  fVCO = FCLKIN / (IDIV_SEL+1) * (FBDIV_SEL+1)
// Math:  fVCO = FCLKIN / (IDIV_SEL+1) * (FBDIV_SEL+1)
//              = 27 / 2 * 55 = 742.5 MHz          (VCO, within 400..1200 MHz)
//        CLKOUT  = fVCO / ODIV_SEL = 742.5 / 1 = 742.5 MHz   (TMDS bit clock, DDR)
//        CLKOUTD = CLKOUT / DYN_SDIV_SEL = 742.5 / 5 = 148.5 MHz (pixel clock)
//
// 148.5 MHz * 2200 * 1125 = 60.0000 Hz，正好整数（CEA-861 VIC 16）。
// 148.5 MHz * 2200 * 1125 = 60.0000 Hz exactly (CEA-861 VIC 16).
module pll_hdmi (
    input  wire clkin,     // 27 MHz
    output wire clkout,    // 742.5 MHz，即 5 倍像素时钟 / 742.5 MHz  = 5x pixel clock
    output wire clkoutd,   // 148.5 MHz，即像素时钟 / 148.5 MHz  = pixel clock
    output wire lock
);

wire gw_gnd;
assign gw_gnd = 1'b0;

rPLL rpll_inst (
    .CLKOUT   (clkout),
    .LOCK     (lock),
    .CLKOUTP  (),
    .CLKOUTD  (clkoutd),
    .CLKOUTD3 (),
    .RESET    (gw_gnd),
    .RESET_P  (gw_gnd),
    .CLKIN    (clkin),
    .CLKFB    (gw_gnd),
    .FBDSEL   ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .IDSEL    ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .ODSEL    ({gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .PSDA     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .DUTYDA   ({gw_gnd, gw_gnd, gw_gnd, gw_gnd}),
    .FDLY     ({gw_gnd, gw_gnd, gw_gnd, gw_gnd})
);

defparam rpll_inst.FCLKIN            = "27";
defparam rpll_inst.DYN_IDIV_SEL      = "false";
defparam rpll_inst.IDIV_SEL          = 1;      // 除以 2 -> 13.5 MHz 鉴相频率 / /2  -> 13.5 MHz PFD
defparam rpll_inst.DYN_FBDIV_SEL     = "false";
defparam rpll_inst.FBDIV_SEL         = 54;     // 乘 55 -> 742.5 MHz VCO / x55 -> 742.5 MHz VCO
defparam rpll_inst.DYN_ODIV_SEL      = "false";
defparam rpll_inst.ODIV_SEL          = 1;      // 除以 1 -> 742.5 MHz / /1  -> 742.5 MHz
defparam rpll_inst.PSDA_SEL          = "0000";
defparam rpll_inst.DYN_DA_EN         = "false";
defparam rpll_inst.DUTYDA_SEL        = "1000";
defparam rpll_inst.CLKOUT_FT_DIR     = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR    = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP   = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP  = 0;
defparam rpll_inst.CLKFB_SEL         = "internal";
defparam rpll_inst.CLKOUT_BYPASS     = "false";
defparam rpll_inst.CLKOUTP_BYPASS    = "false";
defparam rpll_inst.CLKOUTD_BYPASS    = "false";
defparam rpll_inst.DYN_SDIV_SEL      = 5;      // CLKOUTD = 742.5/5 = 148.5
defparam rpll_inst.CLKOUTD_SRC       = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC      = "CLKOUT";
defparam rpll_inst.DEVICE            = "GW2AR-18";

endmodule
