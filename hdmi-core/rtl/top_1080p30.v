// AI-assisted; see NOTICE.md
// 1920x1080 @ 30 Hz 变体 —— 在 371.25 MHz 串行化器上限下，
// 这是本器件实际能达到的最快 1080p。
// 1920x1080 @ 30 Hz variant - the fastest 1080p this device can actually reach
// with the 371.25 MHz serialiser ceiling.
//
// 与 1080p60 目标相同的 CEA-861 光栅（2200 x 1125），但像素时钟是
// 74.25 MHz 而不是 148.5 MHz：
// Same CEA-861 raster (2200 x 1125) as the 1080p60 target, but the pixel clock
// is 74.25 MHz instead of 148.5 MHz:
//      74.25e6 / (2200 * 1125) = 30.000 Hz
// 串行化器跑在 74.25 * 5 = 371.25 MHz（DDR -> 742.5 Mbit/s/通道），
// 这正是 nand2mario/nestang 在该板上做 720p 时使用的速率。
// and the serialiser runs at 74.25 * 5 = 371.25 MHz (DDR -> 742.5 Mbit/s/lane),
// which is exactly the rate nand2mario/nestang ships for 720p on this board.
module top_1080p30 (
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

// ---- 其余部分与 1080p60 设计完全相同 ----
// ---- the rest is identical to the 1080p60 design -------------------------
wire [11:0] cx, cy;
wire        hsync, vsync, active;

hdmi_timing u_timing (
    .clk_pixel(clkpix),
    .reset    (1'b0),
    .cx       (cx),
    .cy       (cy),
    .hsync    (hsync),
    .vsync    (vsync),
    .active   (active)
);

wire [23:0] rgb;

pattern_gen u_pat (
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
