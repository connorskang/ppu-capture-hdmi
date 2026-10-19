// AI-assisted; see NOTICE.md
// 1280x720 @ 60 Hz（CEA-861 VIC 4），面向 Tang Nano 20K / GW2AR-18。
// 1280x720 @ 60 Hz (CEA-861 VIC 4) for the Tang Nano 20K / GW2AR-18.
//
// 这个变体的要点：720p60 需要的时钟与已经可用的 1080p30 构建完全相同。
// The point of this variant: 720p60 needs exactly the same clocks as the
// working 1080p30 build.
//   pixel clock       = 74.25 MHz   (74.25e6 / (1650 * 750) = 60.000 Hz)
//   TMDS bit clock    = 74.25  * 5  = 371.25 MHz  (DDR -> 742.5 Mbit/s/lane)
// 因此 rPLL（371.25 MHz）、CLKDIV /5、TMDS 编码器和 OSER10 串行化器
// 全部原样复用，只有 CEA-861 光栅参数改变。
// so the rPLL (371.25 MHz), the CLKDIV /5, the TMDS encoder and the OSER10
// serialisers are all reused verbatim.  Only the CEA-861 raster changes.
module top_720p60 (
    input  wire       sys_clk,      // 27 MHz，引脚 4 / 27 MHz, pin 4
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire [1:0] led
);

wire clk5;      // 371.25 MHz
wire clkpix;    // 74.25 MHz
wire pll_lock;

pll_hdmi_371 u_pll (
    .clkin (sys_clk),
    .clkout(clk5),
    .lock  (pll_lock)
);

// 371.25 / 5 = 74.25 MHz 像素时钟 / 371.25 / 5 = 74.25 MHz pixel clock
CLKDIV #(.DIV_MODE(5)) u_div5 (
    .CLKOUT (clkpix),
    .HCLKIN (clk5),
    .RESETN (pll_lock),
    .CALIB  (1'b0)
);

// ---- CEA-861 VIC 4 光栅（相对 1080p30 唯一的功能性改动）----
// ---- CEA-861 VIC 4 raster (the ONLY functional change vs. 1080p30) -------
//   H: 有效 1280 | 前肩 110 | 同步 40 | 后肩 220 | 总计 1650
//   H: 1280 active | fp 110 | sync 40 | bp 220 | total 1650
//   V: 有效  720 | 前肩   5 | 同步  5 | 后肩  20 | 总计  750
//   V:  720 active | fp   5 | sync  5 | bp  20 | total  750
wire [11:0] cx, cy;
wire        hsync, vsync, active;

hdmi_timing #(
    .H_ACTIVE (12'd1280),
    .H_FP     (12'd110),
    .H_SYNC   (12'd40),
    .H_BP     (12'd220),
    .V_ACTIVE (12'd720),
    .V_FP     (12'd5),
    .V_SYNC   (12'd5),
    .V_BP     (12'd20)
) u_timing (
    .clk_pixel(clkpix),
    .reset    (1'b0),
    .cx       (cx),
    .cy       (cy),
    .hsync    (hsync),
    .vsync    (vsync),
    .active   (active)
);

wire [23:0] rgb;

pattern_gen #(
    .H_ACTIVE (12'd1280)
) u_pat (
    .cx    (cx),
    .cy    (cy),
    .active(active),
    .rgb   (rgb)
);

wire [9:0] enc0, enc1, enc2;

tmds_encoder u_enc0 (.clk(clkpix), .d(rgb[7:0]),   .c0(hsync), .c1(vsync), .de(active), .q(enc0));
tmds_encoder u_enc1 (.clk(clkpix), .d(rgb[15:8]),  .c0(1'b0),  .c1(1'b0),  .de(active), .q(enc1));
tmds_encoder u_enc2 (.clk(clkpix), .d(rgb[23:16]), .c0(1'b0),  .c1(1'b0),  .de(active), .q(enc2));

wire [2:0] tmds;
wire       tmds_clk_i;

OSER10 ser0 (
    .Q(tmds[0]),
    .D0(enc0[0]), .D1(enc0[1]), .D2(enc0[2]), .D3(enc0[3]), .D4(enc0[4]),
    .D5(enc0[5]), .D6(enc0[6]), .D7(enc0[7]), .D8(enc0[8]), .D9(enc0[9]),
    .PCLK(clkpix), .FCLK(clk5), .RESET(1'b0)
);

OSER10 ser1 (
    .Q(tmds[1]),
    .D0(enc1[0]), .D1(enc1[1]), .D2(enc1[2]), .D3(enc1[3]), .D4(enc1[4]),
    .D5(enc1[5]), .D6(enc1[6]), .D7(enc1[7]), .D8(enc1[8]), .D9(enc1[9]),
    .PCLK(clkpix), .FCLK(clk5), .RESET(1'b0)
);

OSER10 ser2 (
    .Q(tmds[2]),
    .D0(enc2[0]), .D1(enc2[1]), .D2(enc2[2]), .D3(enc2[3]), .D4(enc2[4]),
    .D5(enc2[5]), .D6(enc2[6]), .D7(enc2[7]), .D8(enc2[8]), .D9(enc2[9]),
    .PCLK(clkpix), .FCLK(clk5), .RESET(1'b0)
);

OSER10 ser_clk (
    .Q(tmds_clk_i),
    .D0(1'b1), .D1(1'b1), .D2(1'b1), .D3(1'b1), .D4(1'b1),
    .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0), .D9(1'b0),
    .PCLK(clkpix), .FCLK(clk5), .RESET(1'b0)
);

ELVDS_OBUF bufs [3:0] (
    .I ({tmds_clk_i, tmds}),
    .O ({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

reg [25:0] hb;
always @(posedge clkpix)
    hb <= hb + 26'd1;

assign led = ~{pll_lock, hb[25]};

endmodule
