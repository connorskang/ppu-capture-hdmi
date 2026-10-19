// AI-assisted; see NOTICE.md
// 27 MHz -> 371.25 MHz（TMDS 位时钟），用于*降速*的 1080p 变体。
// 27 MHz -> 371.25 MHz (TMDS bit clock) for the *reduced-rate* 1080p variant.
//
// 1080p60 目标需要在这里输出 742.5 MHz，而 GW2AR-18 的 rPLL 做不到：
// The 1080p60 target needs 742.5 MHz here, which the GW2AR-18 rPLL cannot do:
//   WARN (EX0210): Invalid CLKOUT frequency ... suitable range is 3.90625MHz to 625MHz
//   WARN (EX0210): Invalid VCO frequency ... suitable range is from 500MHz to 1250MHz
// 742.5 MHz > 625 MHz  ->  rPLL 的 CLKOUT 上限就是硬性瓶颈。
// 742.5 MHz > 625 MHz  ->  rPLL CLKOUT limit is the hard blocker.
//
// 371.25 MHz 是合法的：
// 371.25 MHz is legal:
//   fVCO   = 27 / 4 * 55 * 2 = 742.5 MHz     (500..1250  OK)
//   CLKOUT = 27 / 4 * 55     = 371.25 MHz    (<=625      OK)
// 74.25 MHz 的像素时钟随后由顶层的一个 CLKDIV /5 原语产生
// （rPLL 的 CLKOUTD 只能做偶数分频，所以给不出 /5）。
// The 74.25 MHz pixel clock is then produced by a CLKDIV /5 primitive in the top
// level (rPLL CLKOUTD can only divide by EVEN values, so it cannot give /5).
module pll_hdmi_371 (
    input  wire clkin,     // 27 MHz
    output wire clkout,    // 371.25 MHz
    output wire lock
);

wire gw_gnd;
assign gw_gnd = 1'b0;

rPLL rpll_inst (
    .CLKOUT   (clkout),
    .LOCK     (lock),
    .CLKOUTP  (),
    .CLKOUTD  (),
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
defparam rpll_inst.IDIV_SEL          = 3;      // 除以 4 -> 6.75 MHz 鉴相频率 / /4  -> 6.75 MHz PFD
defparam rpll_inst.DYN_FBDIV_SEL     = "false";
defparam rpll_inst.FBDIV_SEL         = 54;     // 乘 55 -> 371.25 MHz / x55 -> 371.25 MHz
defparam rpll_inst.DYN_ODIV_SEL      = "false";
defparam rpll_inst.ODIV_SEL          = 2;      // VCO = 742.5 MHz
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
defparam rpll_inst.DYN_SDIV_SEL      = 2;
defparam rpll_inst.CLKOUTD_SRC       = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC      = "CLKOUT";
defparam rpll_inst.DEVICE            = "GW2AR-18C";

endmodule
