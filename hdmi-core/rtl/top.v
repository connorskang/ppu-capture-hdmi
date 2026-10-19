// AI-assisted; see NOTICE.md
// Tang Nano 20K（GW2AR-LV18QN88C8/I7）- 1080p60 HDMI 测试图案发生器。
// Tang Nano 20K (GW2AR-LV18QN88C8/I7) - 1080p60 HDMI test pattern generator.
//
// 像素时钟 148.5 MHz，TMDS 每通道位率 1.485 Gbit/s。
// Pixel clock 148.5 MHz, TMDS bit rate 1.485 Gbit/s per lane.
// 10:1 串行化器是高云的 OSER10 硬核，PCLK = 148.5 MHz，
// FCLK = 742.5 MHz（DDR：输出在 FCLK 两个边沿都翻转 -> 2*742.5 = 1.485 Gbit/s）。
// The 10:1 serialiser is Gowin's OSER10 hard macro, clocked PCLK = 148.5 MHz,
// FCLK = 742.5 MHz (DDR: output toggles on both FCLK edges -> 2*742.5 = 1.485 Gbit/s).
module top (
    input  wire       sys_clk,      // 27 MHz 晶振，引脚 4 / 27 MHz oscillator, pin 4
    output wire       tmds_clk_p,   // 引脚 33 / 34 / pins 33 / 34
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,     // 引脚 35/36、37/38、39/40 / pins 35/36, 37/38, 39/40
    output wire [2:0] tmds_d_n,
    output wire [1:0] led
);

// ---------------------------------------------------------------- 时钟 / clocks
wire clk5;      // 742.5 MHz
wire clkpix;    // 148.5 MHz
wire pll_lock;

pll_hdmi u_pll (
    .clkin  (sys_clk),
    .clkout (clk5),
    .clkoutd(clkpix),
    .lock   (pll_lock)
);

// ---------------------------------------------------------------- 时序 / timing
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

// ---------------------------------------------------------------- 图案 / pattern
wire [23:0] rgb;

pattern_gen u_pat (
    .cx    (cx),
    .cy    (cy),
    .active(active),
    .rgb   (rgb)
);

// ---------------------------------------------------------------- TMDS 编码 / TMDS encode
wire [9:0] enc0, enc1, enc2;

tmds_encoder u_enc0 (
    .clk(clkpix), .d(rgb[7:0]),  .c0(hsync), .c1(vsync), .de(active), .q(enc0)   // 蓝 / blue
);
tmds_encoder u_enc1 (
    .clk(clkpix), .d(rgb[15:8]), .c0(1'b0),  .c1(1'b0),  .de(active), .q(enc1)   // 绿 / green
);
tmds_encoder u_enc2 (
    .clk(clkpix), .d(rgb[23:16]),.c0(1'b0),  .c1(1'b0),  .de(active), .q(enc2)   // 红 / red
);

// ---------------------------------------------------------------- 串行化 / serialise
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

// TMDS 时钟通道：每个像素 5 个 1 再 5 个 0 -> 每个像素时钟一个完整周期
// TMDS clock lane: 5 ones then 5 zeros per pixel -> one full period per pixel clock
OSER10 ser_clk (
    .Q(tmds_clk_i),
    .D0(1'b1), .D1(1'b1), .D2(1'b1), .D3(1'b1), .D4(1'b1),
    .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0), .D9(1'b0),
    .PCLK(clkpix), .FCLK(clk5), .RESET(1'b0)
);

// ---------------------------------------------------------------- 输出缓冲 / output buffers
ELVDS_OBUF bufs [3:0] (
    .I ({tmds_clk_i, tmds}),
    .O ({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

// ---------------------------------------------------------------- 状态指示灯 / status LED
reg [25:0] hb;
always @(posedge clkpix)
    hb <= hb + 26'd1;

assign led = ~{pll_lock, hb[25]};

endmodule
