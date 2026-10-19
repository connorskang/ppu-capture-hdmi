// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// tb_ppu_hdmi_720p.v -- PPU -> HDMI（720p60）集成通路的自检 testbench。
// tb_ppu_hdmi_720p.v -- self-checking testbench for the 720p60 integrated
//                      PPU -> HDMI path.
//
//   PPU 光栅 + 调色板写  ->  ppu_capture_intercept  ->  帧缓冲
//        ->  ppu_video_pipeline_720p (4:3, 960x720)  -> rgb_43 --\
//        ->  ppu_video_pipeline_720p (1:1, 1024x720) -> rgb_1x ----> 被检查
//   PPU raster + palette writes  ->  ppu_capture_intercept  ->  framebuffer
//        ->  ppu_video_pipeline_720p (4:3, 960x720)  -> rgb_43 --\
//        ->  ppu_video_pipeline_720p (1:1, 1024x720) -> rgb_1x ----> checked
//
// 第 1 阶段（PPU 像素时钟，5.369 MHz）：通过 CPU 寄存器总线编程调色板，在
//   EXT0..3 + EXT4 以及比较器时序输入上驱动三个完整的 NTSC 形状源帧
//   （341 点 x 262 行，有效区 256x240），然后逐条校验全部 61440 个帧缓冲表项。
// 第 2 阶段（视频像素时钟，74.25 MHz）：一个完整的 1650x750 720p60 帧，
//   两个模式实例并行读同一份帧缓冲。
// Phase 1 (PPU pixel clock, 5.369 MHz): program the palette through the CPU
//   register bus, drive three complete NTSC-shaped source frames (341 dots x
//   262 lines, 256x240 active) on EXT0..3 + EXT4 and the comparator timing
//   inputs, then verify EVERY ONE of the 61440 framebuffer entries.
// Phase 2 (video pixel clock, 74.25 MHz): one complete 1650x750 720p60 frame
//   read out of the same framebuffer by both mode instances in parallel.
//
// 检查内容 / what is checked:
//   1. 逐像素 RGB（含混合 + 扫描线衰减）对独立黄金模型；
//      per-pixel RGB (blend + scanline attenuation) against an independent
//      golden model;
//   2. 实际取址 raddr_o、源列 sx_o、stage-A 相位 a3_o、混合权重 wgt_o
//      全部对齐后逐个比对（颜色相同但取错源像素的情况也会被抓到）；
//      the actual fetch address, source column, stage-A phase and blend weight,
//      all aligned and compared one by one (so a wrong-but-same-coloured fetch
//      is still caught);
//   3. 画面矩形：整行扫描统计"非边框列数"，两种模式都必须正好是
//      960 / 1024 列，起点 160 / 128；
//      picture rectangle: a whole-row census of non-border columns must be
//      exactly 960 / 1024 wide, starting at 160 / 128;
//   4. stage A 的整数重复精确性：源列每列正好 3 个 stage-A 采样点，
//      相位严格按 0,1,2 循环（1:1 模式 0,1,2,3）；
//      stage-A integer-repeat exactness: exactly three stage-A samples per
//      source column, phase strictly cycling 0,1,2 (0,1,2,3 in 1:1 mode);
//   5. 垂直 3 倍：每 3 个输出行对应 1 个源行，相位落在正确的行上；
//      vertical 3x: three output rows per source row, phase on the right rows;
//   6. 命名点（画面四角/中心/边框/扫描线三档）逐点报告。
//      named points (corners, centre, borders, the three scanline levels).
//
// 黄金模型用的是**直接推导**（j = floor(4i/5)、f = frac(4i/5)、sL = floor(j/3)），
// 与 DUT 的计数器实现是两套算法；这正是它能发现问题的原因。
// The golden model is derived directly (j = floor(4i/5), f = frac(4i/5),
// sL = floor(j/3)) while the DUT uses counters -- two different algorithms,
// which is exactly why the comparison is worth something.
//
// 运行方式：见 sim/run_720p.ps1。加 -Vcd 可导出波形。
// Run: see sim/run_720p.ps1.  Add -Vcd for a waveform.
// -----------------------------------------------------------------------------

module tb_ppu_hdmi_720p;

    // ------------------------------------------------------------------
    // 被测设计的几何常数 / geometry constants of the design under test
    // ------------------------------------------------------------------
    localparam [11:0] H_ACTIVE = 12'd1280;
    localparam [11:0] V_ACTIVE = 12'd720;
    localparam [11:0] H_TOTAL  = 12'd1650;
    localparam [11:0] V_TOTAL  = 12'd750;

    localparam integer V_START    = 0;     // (720-720)/2
    localparam integer PIC_H      = 720;   // 240 * 3
    localparam integer H_OUT_43   = 960;   // 720 * 4/3
    localparam integer H_OUT_1X   = 1024;  // 256 * 4
    localparam integer H_START_43 = 160;   // (1280-960)/2
    localparam integer H_START_1X = 128;   // (1280-1024)/2

    // 锐利双线性的阈值（1/256 单位），与 RTL 默认值一致但**独立写出**
    // sharp-bilinear thresholds (1/256 units), same values as the RTL defaults
    // but written out here independently
    localparam integer T_LO = 51;
    localparam integer T_HI = 205;

    localparam [23:0] BORDER = 24'h303030;

    // PPU 光栅（NTSC 形状）/ PPU raster (NTSC-shaped)
    localparam integer LINE_DOTS = 341;
    localparam integer N_LINES   = 262;
    localparam integer ACT_START = 4;
    localparam integer ACT_LEN   = 256;
    localparam integer ACT_LINES = 240;
    localparam integer HS_WIDTH  = 4;
    localparam integer VS_FIRST  = 258;
    localparam integer VS_LAST   = 260;

    localparam integer V_FRAME_CLKS = 1650 * 750;

    // ------------------------------------------------------------------
    // 时钟（带门控）/ clocks (gated)
    // ------------------------------------------------------------------
    reg clk_ppu = 1'b0;      // 186.24 ns -> 5.369 MHz (2C02 dot clock)
    reg clk_pix = 1'b0;      //  13.468 ns -> 74.25 MHz (720p60 pixel clock)
    reg ppu_run = 1'b1;
    reg pix_run = 1'b0;

    initial begin
        forever begin
            wait (ppu_run);
            #93.12 clk_ppu = 1'b1;
            #93.12 clk_ppu = 1'b0;
        end
    end

    initial begin
        forever begin
            wait (pix_run);
            #6.734 clk_pix = 1'b1;
            #6.734 clk_pix = 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // DUT 信号 / DUT signals
    // ------------------------------------------------------------------
    reg         rst_n    = 1'b0;
    reg         vid_rst  = 1'b1;

    reg         cpu_cs_n = 1'b1;
    reg         cpu_rw   = 1'b1;
    reg  [2:0]  cpu_a    = 3'b000;
    reg  [7:0]  cpu_d_in = 8'h00;

    reg  [3:0]  ext_i    = 4'h0;
    reg         ext4_i   = 1'b0;
    reg         vsync_i  = 1'b0;

    wire        ext_hsync;
    wire        ext_blank;

    wire [5:0]  pix_index;
    wire        pix_valid;

    wire [23:0] rgb_1x, rgb_43;
    wire        de;
    wire [11:0] cx_o, cy_o;

    wire [15:0] raddr_1x, raddr_43;
    wire [7:0]  sx_1x, sx_43;
    wire [1:0]  a3_1x, a3_43;
    wire [8:0]  wgt_1x, wgt_43;

    wire [7:0]  cpu_d_out;
    wire        cpu_d_oe;

    // ------------------------------------------------------------------
    // 黄金模型：源图案 -> 调色板地址 / golden model: source pattern -> palette addr
    // ------------------------------------------------------------------
    // 源像素 (x,y) 的 5 位调色板地址：
    // 5-bit palette address for source pixel (x,y):
    //     { x[7], y[7], x[1], 1'b1, x[0] }
    // bit 1 恒为 1，因此该地址永远不会落在四个通用背景色镜像上，图案只覆盖
    // 8 个不同的调色板表项。
    // Bit 1 is constant 1, so the address can never be one of the four
    // universal-backdrop mirrors; the pattern therefore covers 8 distinct
    // palette entries.
    function [4:0] src_addr;
        input [7:0] x;
        input [7:0] y;
        begin
            src_addr = {x[7], y[7], x[1], 1'b1, x[0]};
        end
    endfunction

    function [5:0] pal_code;
        input [4:0] a;
        reg [3:0] k;
        begin
            k = {a[4], a[3], a[1], a[0]};
            case (k)
                4'd0:  pal_code = 6'd32;   // 0x30 eceeec
                4'd1:  pal_code = 6'd22;   // 0x16 982220
                4'd2:  pal_code = 6'd26;   // 0x1a 087c00
                4'd3:  pal_code = 6'd18;   // 0x12 3032ec
                4'd4:  pal_code = 6'd33;   // 0x21 4c9aec
                4'd5:  pal_code = 6'd21;   // 0x15 a01464
                4'd6:  pal_code = 6'd44;   // 0x2c 38b4cc
                4'd7:  pal_code = 6'd56;   // 0x38 ccd278
                4'd8:  pal_code = 6'd3;    // 0x03 300088
                4'd9:  pal_code = 6'd7;    // 0x07 3c1800
                4'd10: pal_code = 6'd12;   // 0x0c 00323c
                4'd11: pal_code = 6'd28;   // 0x1c 006678
                4'd12: pal_code = 6'd40;   // 0x28 a0aa00
                4'd13: pal_code = 6'd36;   // 0x24 e454ec
                4'd14: pal_code = 6'd43;   // 0x2b 38cc6c
                default: pal_code = 6'd2;  // 0x02 081090
            endcase
        end
    endfunction

    // 64 项 2C02 RGB 表，独立于 rtl/nes_palette.v 另行录入（互为交叉校验）。
    // 64-entry 2C02 RGB table, transcribed independently of rtl/nes_palette.v.
    function [23:0] pal_rgb_model;
        input [5:0] idx;
        begin
            case (idx)
                6'd0:  pal_rgb_model = 24'h545454;
                6'd1:  pal_rgb_model = 24'h001e74;
                6'd2:  pal_rgb_model = 24'h081090;
                6'd3:  pal_rgb_model = 24'h300088;
                6'd4:  pal_rgb_model = 24'h440064;
                6'd5:  pal_rgb_model = 24'h5c0030;
                6'd6:  pal_rgb_model = 24'h540400;
                6'd7:  pal_rgb_model = 24'h3c1800;
                6'd8:  pal_rgb_model = 24'h202a00;
                6'd9:  pal_rgb_model = 24'h083a00;
                6'd10: pal_rgb_model = 24'h004000;
                6'd11: pal_rgb_model = 24'h003c00;
                6'd12: pal_rgb_model = 24'h00323c;
                6'd13: pal_rgb_model = 24'h000000;
                6'd14: pal_rgb_model = 24'h000000;
                6'd15: pal_rgb_model = 24'h000000;
                6'd16: pal_rgb_model = 24'h989698;
                6'd17: pal_rgb_model = 24'h084cc4;
                6'd18: pal_rgb_model = 24'h3032ec;
                6'd19: pal_rgb_model = 24'h5c1ee4;
                6'd20: pal_rgb_model = 24'h8814b0;
                6'd21: pal_rgb_model = 24'ha01464;
                6'd22: pal_rgb_model = 24'h982220;
                6'd23: pal_rgb_model = 24'h783c00;
                6'd24: pal_rgb_model = 24'h545a00;
                6'd25: pal_rgb_model = 24'h287200;
                6'd26: pal_rgb_model = 24'h087c00;
                6'd27: pal_rgb_model = 24'h007628;
                6'd28: pal_rgb_model = 24'h006678;
                6'd29: pal_rgb_model = 24'h000000;
                6'd30: pal_rgb_model = 24'h000000;
                6'd31: pal_rgb_model = 24'h000000;
                6'd32: pal_rgb_model = 24'heceeec;
                6'd33: pal_rgb_model = 24'h4c9aec;
                6'd34: pal_rgb_model = 24'h787cec;
                6'd35: pal_rgb_model = 24'hb062ec;
                6'd36: pal_rgb_model = 24'he454ec;
                6'd37: pal_rgb_model = 24'hec58b4;
                6'd38: pal_rgb_model = 24'hec6a64;
                6'd39: pal_rgb_model = 24'hd48820;
                6'd40: pal_rgb_model = 24'ha0aa00;
                6'd41: pal_rgb_model = 24'h74c400;
                6'd42: pal_rgb_model = 24'h4cd020;
                6'd43: pal_rgb_model = 24'h38cc6c;
                6'd44: pal_rgb_model = 24'h38b4cc;
                6'd45: pal_rgb_model = 24'h3c3c3c;
                6'd46: pal_rgb_model = 24'h000000;
                6'd47: pal_rgb_model = 24'h000000;
                6'd48: pal_rgb_model = 24'heceeec;
                6'd49: pal_rgb_model = 24'ha8ccec;
                6'd50: pal_rgb_model = 24'hbcbcec;
                6'd51: pal_rgb_model = 24'hd4b2ec;
                6'd52: pal_rgb_model = 24'hecaeec;
                6'd53: pal_rgb_model = 24'hecaed4;
                6'd54: pal_rgb_model = 24'hecb4b0;
                6'd55: pal_rgb_model = 24'he4c490;
                6'd56: pal_rgb_model = 24'hccd278;
                6'd57: pal_rgb_model = 24'hb4de78;
                6'd58: pal_rgb_model = 24'ha8e290;
                6'd59: pal_rgb_model = 24'h98e2b4;
                6'd60: pal_rgb_model = 24'ha0d6e4;
                6'd61: pal_rgb_model = 24'ha0a2a0;
                6'd62: pal_rgb_model = 24'h000000;
                6'd63: pal_rgb_model = 24'h000000;
                default: pal_rgb_model = 24'h000000;
            endcase
        end
    endfunction

    // 扫描线三档亮度，1/256 单位。/ Scanline level for phase 0..2, 1/256 units.
    function integer lvl_of;
        input integer ph;
        begin
            case (ph)
                0: lvl_of = 256;    // 亮 / bright
                1: lvl_of = 128;    // 半 / half
                default: lvl_of = 0; // 暗 / dark
            endcase
        end
    endfunction

    function [7:0] dim8;
        input [7:0] v;
        input integer lvl;
        begin
            dim8 = (v * lvl) >> 8;
        end
    endfunction

    // 线性混合：w 是右侧抽头的权重（0..256）
    // linear blend: w is the weight of the right tap (0..256)
    function [7:0] mix8f;
        input [7:0] a;
        input [7:0] b;
        input integer w;
        begin
            mix8f = (a * (256 - w) + b * w) >> 8;
        end
    endfunction

    // ------------------------------------------------------------------
    // 黄金模型（直接推导，不使用 DUT 的计数器）
    // Golden model (derived directly, does not use the DUT's counters)
    // ------------------------------------------------------------------
    reg        m_inpic;
    reg [15:0] m_addr;
    reg [7:0]  m_sx;
    reg [1:0]  m_a3;
    reg [8:0]  m_wgt;
    reg [23:0] m_rgb;

    task model;
        input integer mode43;
        input [11:0] px;
        input [11:0] py;
        integer hstart, hout, i, j, a3i, sL, sR, f256, w, syi, vphi;
        reg [7:0] xl, xr, yl;
        reg [5:0] cl, cr;
        reg [23:0] rl, rr;
        begin
            if (mode43) begin hstart = H_START_43; hout = H_OUT_43; end
            else        begin hstart = H_START_1X; hout = H_OUT_1X; end

            if ((px < hstart) || (px >= (hstart + hout)) ||
                (py < V_START) || (py >= (V_START + PIC_H))) begin
                m_inpic = 1'b0;
                m_addr  = 16'd0;
                m_sx    = 8'd0;
                m_a3    = 2'd0;
                m_wgt   = 9'd0;
                m_rgb   = BORDER;
            end else begin
                i    = px - hstart;
                syi  = (py - V_START) / 3;      // 3 倍垂直 / 3x vertical
                vphi = (py - V_START) % 3;

                if (mode43) begin
                    j    = (4 * i) / 5;                 // stage-A 位置 / stage-A position
                    a3i  = j % 3;
                    sL   = j / 3;                       // == floor(4i/15)
                    f256 = (((4 * i) % 5) * 256 + 2) / 5;   // round(frac(4i/5)*256)
                    if      (f256 < T_LO) w = 0;
                    else if (f256 > T_HI) w = 256;
                    else                  w = f256;
                    if ((a3i == 2) && (sL != 255)) sR = sL + 1;
                    else                           sR = sL;
                end else begin
                    j    = i;
                    a3i  = i % 4;
                    sL   = i / 4;
                    sR   = sL;
                    w    = 0;
                end

                m_inpic = 1'b1;
                m_addr  = syi * 256 + sR;
                m_sx    = sL;
                m_a3    = a3i[1:0];
                m_wgt   = w;

                xl = sL;
                xr = sR;
                yl = syi;
                cl = pal_code(src_addr(xl, yl));
                cr = pal_code(src_addr(xr, yl));
                rl = pal_rgb_model(cl);
                rr = pal_rgb_model(cr);
                m_rgb = { dim8(mix8f(rl[23:16], rr[23:16], w), lvl_of(vphi)),
                          dim8(mix8f(rl[15:8],  rr[15:8],  w), lvl_of(vphi)),
                          dim8(mix8f(rl[7:0],   rr[7:0],   w), lvl_of(vphi)) };
            end
        end
    endtask

    // 做 100% 穷举水平扫描的行（画面上下边缘 + 中段 + 相位切换行）
    // Rows that get a 100 % exhaustive horizontal sweep (picture top/bottom
    // edges, middle, phase-change rows)
    function is_sweep_row;
        input [11:0] y;
        begin
            case (y)
                12'd0, 12'd1, 12'd2, 12'd3, 12'd4, 12'd5,
                12'd100,
                12'd357, 12'd358, 12'd359, 12'd360, 12'd361, 12'd362,
                12'd512,
                12'd713, 12'd714, 12'd715, 12'd716, 12'd717, 12'd718, 12'd719:
                    is_sweep_row = 1'b1;
                default: is_sweep_row = 1'b0;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // DUT：采集通路 / DUT: capture path
    // ------------------------------------------------------------------
    ppu_capture_intercept u_cap (
        .clk                 (clk_ppu),
        .rst_n               (rst_n),
        .phi2                (clk_ppu),
        .cpu_cs_n            (cpu_cs_n),
        .cpu_rw              (cpu_rw),
        .cpu_a               (cpu_a),
        .cpu_d_in            (cpu_d_in),
        .cpu_d_out           (cpu_d_out),
        .cpu_d_oe            (cpu_d_oe),
        .ppu_cs_n            (),
        .ppu_rw              (),
        .ppu_a               (),
        .ppu_d_out           (),
        .ppu_d_oe            (),
        .ppu_d_in            (8'h00),
        .ext_i               (ext_i),
        .ext4_bg_sprite_i    (ext4_i),
        .hsync_i             (ext_hsync),
        .vsync_i             (vsync_i),
        .blank_i             (ext_blank),
        .pixel_index_o       (pix_index),
        .pixel_palette_addr_o(),
        .pixel_valid_o       (pix_valid),
        .emphasis_o          (),
        .grayscale_o         (),
        .capture_en          (1'b1),
        .inject_req          (1'b0),
        .inject_ack          (),
        .inject_busy         (),
        .inject_collision    (),
        .ctrl_shadow         (),
        .ext_out_bit_held    ()
    );

    // ------------------------------------------------------------------
    // DUT：两条 720p60 视频流水线（4:3 = 960 宽 / 1:1 = 1024 宽），共用同一份源
    // DUT: two 720p60 video pipelines (4:3 = 960 wide / 1:1 = 1024 wide), same source
    // ------------------------------------------------------------------
    ppu_video_pipeline_720p #(
        .H_ACTIVE (H_ACTIVE), .V_ACTIVE (V_ACTIVE),
        .H_FP (12'd110), .H_SYNC (12'd40), .H_BP (12'd220),
        .V_FP (12'd5),   .V_SYNC (12'd5),  .V_BP (12'd20)
    ) u_vid_1x (
        .clk       (clk_pix),
        .rst       (vid_rst),
        .wr_clk    (clk_ppu),
        .wr_rst_n  (rst_n),
        .wr_en     (pix_valid),
        .wr_data   (pix_index),
        .wr_vsync  (vsync_i),
        .h_mode_43 (1'b0),
        .rgb       (rgb_1x),
        .de        (de),
        .hsync     (),
        .vsync     (),
        .cx_o      (cx_o),
        .cy_o      (cy_o),
        .raddr_o   (raddr_1x),
        .sx_o      (sx_1x),
        .a3_o      (a3_1x),
        .wgt_o     (wgt_1x)
    );

    ppu_video_pipeline_720p #(
        .H_ACTIVE (H_ACTIVE), .V_ACTIVE (V_ACTIVE),
        .H_FP (12'd110), .H_SYNC (12'd40), .H_BP (12'd220),
        .V_FP (12'd5),   .V_SYNC (12'd5),  .V_BP (12'd20)
    ) u_vid_43 (
        .clk       (clk_pix),
        .rst       (vid_rst),
        .wr_clk    (clk_ppu),
        .wr_rst_n  (rst_n),
        .wr_en     (pix_valid),
        .wr_data   (pix_index),
        .wr_vsync  (vsync_i),
        .h_mode_43 (1'b1),
        .rgb       (rgb_43),
        .de        (),
        .hsync     (),
        .vsync     (),
        .cx_o      (),
        .cy_o      (),
        .raddr_o   (raddr_43),
        .sx_o      (sx_43),
        .a3_o      (a3_43),
        .wgt_o     (wgt_43)
    );

    // ------------------------------------------------------------------
    // PPU 侧光栅发生器 / PPU-side raster generator
    // ------------------------------------------------------------------
    reg [9:0] dot;
    reg [8:0] line;

    always @(posedge clk_ppu or negedge rst_n) begin
        if (!rst_n) begin
            dot  <= 10'd0;
            line <= 9'd0;
        end else begin
            if (dot == LINE_DOTS - 1) begin
                dot  <= 10'd0;
                line <= (line == N_LINES - 1) ? 9'd0 : (line + 9'd1);
            end else begin
                dot <= dot + 10'd1;
            end
        end
    end

    wire ppu_active = (dot >= ACT_START) && (dot < (ACT_START + ACT_LEN)) &&
                      (line < ACT_LINES);
    wire [7:0] ppx = dot[7:0] - 8'd4;
    wire [7:0] ppy = line[7:0];
    wire [4:0] ppa = src_addr(ppx, ppy);

    assign ext_hsync = (dot < HS_WIDTH);
    assign ext_blank = ~ppu_active;

    always @(*) begin
        if (ppu_active) begin
            ext_i  = ppa[3:0];
            ext4_i = ppa[4];
        end else begin
            ext_i  = 4'h0;
            ext4_i = 1'b0;
        end
    end

    always @(*) begin
        vsync_i = (line >= VS_FIRST) && (line <= VS_LAST);
    end

    // ------------------------------------------------------------------
    // 检查器 / checkers
    // ------------------------------------------------------------------
    integer checks = 0;
    integer errors = 0;
    integer shown  = 0;

    integer pix_checks   = 0;
    integer named_checks = 0;
    integer fb_checks    = 0;
    integer sa_checks    = 0;

    // 画面矩形统计（整行普查）/ picture-rectangle census (whole row)
    integer wcnt43 = 0, wcnt1x = 0;
    integer wfirst43 = -1, wlast43 = -1;
    integer wfirst1x = -1, wlast1x = -1;
    integer vcnt43 = 0, vcnt1x = 0;
    integer de_below_err = 0;

    // stage-A 跟踪（第 0 行）/ stage-A tracker (row 0)
    reg  [1:0] prev_a3_43, prev_a3_1x;
    reg  [7:0] prev_sx_43, prev_sx_1x;
    reg        have_43 = 1'b0, have_1x = 1'b0;
    integer    sa_steps43 = 0, sa_sxinc43 = 0, sa_err43 = 0;
    integer    sa_steps1x = 0, sa_sxinc1x = 0, sa_err1x = 0;
    integer    pa3, psx;

    reg [23:0] cap43 [0:15];
    reg [23:0] cap1x [0:15];
    reg        seen43 [0:15];
    reg        seen1x [0:15];
    integer    k;
    initial begin
        for (k = 0; k < 16; k = k + 1) begin
            seen43[k] = 1'b0;
            seen1x[k] = 1'b0;
            cap43[k]  = 24'h0;
            cap1x[k]  = 24'h0;
        end
    end

    always @(posedge clk_pix) begin
        if (pix_run && de) begin

            // ---------------- 4:3 模式 / 4:3 mode ----------------
            if (is_sweep_row(cy_o) || ((cx_o % 12'd128) == 12'd0)) begin
                model(1, cx_o, cy_o);
                if (!m_inpic) begin
                    if (rgb_43 !== BORDER) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [4:3] (%0d,%0d) expected border %06h, got %06h",
                                     cx_o, cy_o, BORDER, rgb_43);
                            shown = shown + 1;
                        end
                    end
                end else begin
                    if (raddr_43 !== m_addr) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [4:3] (%0d,%0d) fetch addr %0d, expected %0d",
                                     cx_o, cy_o, raddr_43, m_addr);
                            shown = shown + 1;
                        end
                    end
                    if (sx_43 !== m_sx) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [4:3] (%0d,%0d) sx %0d, expected %0d",
                                     cx_o, cy_o, sx_43, m_sx);
                            shown = shown + 1;
                        end
                    end
                    if (a3_43 !== m_a3) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [4:3] (%0d,%0d) a3 %0d, expected %0d",
                                     cx_o, cy_o, a3_43, m_a3);
                            shown = shown + 1;
                        end
                    end
                    if (wgt_43 !== m_wgt) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [4:3] (%0d,%0d) weight %0d, expected %0d",
                                     cx_o, cy_o, wgt_43, m_wgt);
                            shown = shown + 1;
                        end
                    end
                    if (rgb_43 !== m_rgb) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [4:3] (%0d,%0d) rgb %06h, expected %06h (sx %0d/%0d a3 %0d w %0d)",
                                     cx_o, cy_o, rgb_43, m_rgb, m_sx, m_sx + (m_a3 == 2 ? 1 : 0),
                                     m_a3, m_wgt);
                            shown = shown + 1;
                        end
                    end
                end
                checks     = checks + 1;
                pix_checks = pix_checks + 1;
            end

            // ---------------- 1:1 模式 / 1:1 mode ----------------
            if (is_sweep_row(cy_o) || ((cx_o % 12'd128) == 12'd0)) begin
                model(0, cx_o, cy_o);
                if (!m_inpic) begin
                    if (rgb_1x !== BORDER) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [1:1] (%0d,%0d) expected border %06h, got %06h",
                                     cx_o, cy_o, BORDER, rgb_1x);
                            shown = shown + 1;
                        end
                    end
                end else begin
                    if (raddr_1x !== m_addr) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [1:1] (%0d,%0d) fetch addr %0d, expected %0d",
                                     cx_o, cy_o, raddr_1x, m_addr);
                            shown = shown + 1;
                        end
                    end
                    if (sx_1x !== m_sx) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [1:1] (%0d,%0d) sx %0d, expected %0d",
                                     cx_o, cy_o, sx_1x, m_sx);
                            shown = shown + 1;
                        end
                    end
                    if (a3_1x !== m_a3) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [1:1] (%0d,%0d) a3 %0d, expected %0d",
                                     cx_o, cy_o, a3_1x, m_a3);
                            shown = shown + 1;
                        end
                    end
                    if (rgb_1x !== m_rgb) begin
                        errors = errors + 1;
                        if (shown < 20) begin
                            $display("    FAIL  [1:1] (%0d,%0d) rgb %06h, expected %06h",
                                     cx_o, cy_o, rgb_1x, m_rgb);
                            shown = shown + 1;
                        end
                    end
                end
                checks     = checks + 1;
                pix_checks = pix_checks + 1;
            end

            // ---------------- 第 360 行的画面宽度普查 / row-360 width census ----------------
            if (cy_o == 12'd360) begin
                if (rgb_43 !== BORDER) begin
                    if (wfirst43 < 0) wfirst43 = cx_o;
                    wlast43 = cx_o;
                    wcnt43  = wcnt43 + 1;
                end
                if (rgb_1x !== BORDER) begin
                    if (wfirst1x < 0) wfirst1x = cx_o;
                    wlast1x = cx_o;
                    wcnt1x  = wcnt1x + 1;
                end
            end

            // ---------------- 第 0 列的画面高度普查 / column census for picture height ---
            if (cx_o == H_START_43) begin
                if (rgb_43 !== BORDER) vcnt43 = vcnt43 + 1;
            end
            if (cx_o == H_START_1X) begin
                if (rgb_1x !== BORDER) vcnt1x = vcnt1x + 1;
            end

            // ---------------- 第 0 行的 stage-A 跟踪 / stage-A tracker on row 0 ----------------
            if ((cy_o == 12'd0) && (cx_o >= H_START_43) && (cx_o < (H_START_43 + H_OUT_43))) begin
                if (!have_43) begin
                    have_43   <= 1'b1;
                    prev_a3_43 <= a3_43;
                    prev_sx_43 <= sx_43;
                end else begin
                    pa3 = prev_a3_43;
                    psx = prev_sx_43;
                    if (a3_43 !== prev_a3_43) begin
                        sa_steps43 = sa_steps43 + 1;
                        if (a3_43 !== ((pa3 + 1) % 3)) sa_err43 = sa_err43 + 1;
                    end
                    if (sx_43 !== prev_sx_43) begin
                        sa_sxinc43 = sa_sxinc43 + 1;
                        if ((sx_43 !== ((psx + 1) % 256)) || (a3_43 !== 2'd0))
                            sa_err43 = sa_err43 + 1;
                    end
                    prev_a3_43 <= a3_43;
                    prev_sx_43 <= sx_43;
                end
            end
            if ((cy_o == 12'd0) && (cx_o >= H_START_1X) && (cx_o < (H_START_1X + H_OUT_1X))) begin
                if (!have_1x) begin
                    have_1x   <= 1'b1;
                    prev_a3_1x <= a3_1x;
                    prev_sx_1x <= sx_1x;
                end else begin
                    pa3 = prev_a3_1x;
                    psx = prev_sx_1x;
                    if (a3_1x !== prev_a3_1x) begin
                        sa_steps1x = sa_steps1x + 1;
                        if (a3_1x !== ((pa3 + 1) % 4)) sa_err1x = sa_err1x + 1;
                    end
                    if (sx_1x !== prev_sx_1x) begin
                        sa_sxinc1x = sa_sxinc1x + 1;
                        if ((sx_1x !== ((psx + 1) % 256)) || (a3_1x !== 2'd0))
                            sa_err1x = sa_err1x + 1;
                    end
                    prev_a3_1x <= a3_1x;
                    prev_sx_1x <= sx_1x;
                end
            end

            // ---------------- 命名点采集 / named-point capture ----------------
            case (cx_o)
                H_START_43 - 1: begin
                    if (cy_o == 12'd0)   begin cap43[0]  = rgb_43; seen43[0]  = 1'b1; end
                end
                H_START_43: begin
                    case (cy_o)
                        12'd0:   begin cap43[1]  = rgb_43; seen43[1]  = 1'b1; end
                        12'd1:   begin cap43[2]  = rgb_43; seen43[2]  = 1'b1; end
                        12'd2:   begin cap43[3]  = rgb_43; seen43[3]  = 1'b1; end
                        12'd3:   begin cap43[4]  = rgb_43; seen43[4]  = 1'b1; end
                        12'd360: begin cap43[5]  = rgb_43; seen43[5]  = 1'b1; end
                        default: ;
                    endcase
                end
                H_START_43 + H_OUT_43 - 1: begin
                    if (cy_o == 12'd0)   begin cap43[6]  = rgb_43; seen43[6]  = 1'b1; end
                    if (cy_o == 12'd717) begin cap43[7]  = rgb_43; seen43[7]  = 1'b1; end
                end
                H_START_43 + H_OUT_43: begin
                    if (cy_o == 12'd0)   begin cap43[8]  = rgb_43; seen43[8]  = 1'b1; end
                end
                12'd400: begin
                    case (cy_o)
                        12'd0:   begin cap43[9]  = rgb_43; seen43[9]  = 1'b1; end
                        12'd1:   begin cap43[10] = rgb_43; seen43[10] = 1'b1; end
                        12'd2:   begin cap43[11] = rgb_43; seen43[11] = 1'b1; end
                        default: ;
                    endcase
                end
                12'd639: begin
                    if (cy_o == 12'd360) begin cap43[12] = rgb_43; seen43[12] = 1'b1; end
                end
                default: ;
            endcase

            case (cx_o)
                H_START_1X - 1: begin
                    if (cy_o == 12'd0)   begin cap1x[0]  = rgb_1x; seen1x[0]  = 1'b1; end
                end
                H_START_1X: begin
                    case (cy_o)
                        12'd0:   begin cap1x[1]  = rgb_1x; seen1x[1]  = 1'b1; end
                        12'd1:   begin cap1x[2]  = rgb_1x; seen1x[2]  = 1'b1; end
                        12'd2:   begin cap1x[3]  = rgb_1x; seen1x[3]  = 1'b1; end
                        12'd3:   begin cap1x[4]  = rgb_1x; seen1x[4]  = 1'b1; end
                        12'd719: begin cap1x[5]  = rgb_1x; seen1x[5]  = 1'b1; end
                        default: ;
                    endcase
                end
                H_START_1X + 3: begin
                    if (cy_o == 12'd0)   begin cap1x[6]  = rgb_1x; seen1x[6]  = 1'b1; end
                end
                H_START_1X + 4: begin
                    if (cy_o == 12'd0)   begin cap1x[7]  = rgb_1x; seen1x[7]  = 1'b1; end
                end
                H_START_1X + H_OUT_1X - 1: begin
                    if (cy_o == 12'd0)   begin cap1x[8]  = rgb_1x; seen1x[8]  = 1'b1; end
                end
                H_START_1X + H_OUT_1X: begin
                    if (cy_o == 12'd0)   begin cap1x[9]  = rgb_1x; seen1x[9]  = 1'b1; end
                end
                12'd400: begin
                    case (cy_o)
                        12'd0:   begin cap1x[10] = rgb_1x; seen1x[10] = 1'b1; end
                        12'd1:   begin cap1x[11] = rgb_1x; seen1x[11] = 1'b1; end
                        12'd2:   begin cap1x[12] = rgb_1x; seen1x[12] = 1'b1; end
                        default: ;
                    endcase
                end
                12'd639: begin
                    if (cy_o == 12'd360) begin cap1x[13] = rgb_1x; seen1x[13] = 1'b1; end
                end
                default: ;
            endcase

            // ---------------- 列模式抽查表（4:3，第 0 行，i = 0..19）----------------
            if ((cy_o == 12'd0) && (cx_o >= H_START_43) &&
                (cx_o < (H_START_43 + 12'd20))) begin
                model(1, cx_o, cy_o);
                $display("    col i=%0d cx=%0d | DUT sx=%0d a3=%0d w=%0d addr=%0d rgb=%06h | exp sx=%0d a3=%0d w=%0d addr=%0d rgb=%06h  %0s",
                         cx_o - H_START_43, cx_o,
                         sx_43, a3_43, wgt_43, raddr_43, rgb_43,
                         m_sx, m_a3, m_wgt, m_addr, m_rgb,
                         ({sx_43, a3_43, wgt_43, raddr_43, rgb_43} ===
                          {m_sx,  m_a3,  m_wgt,  m_addr,  m_rgb})  ? "ok" : "MISMATCH");
            end
            // 1:1 模式前 8 列的整数 4 倍重复 / first 8 columns of 1:1 mode
            if ((cy_o == 12'd0) && (cx_o >= H_START_1X) &&
                (cx_o < (H_START_1X + 12'd8))) begin
                model(0, cx_o, cy_o);
                $display("    col i=%0d cx=%0d | DUT sx=%0d a3=%0d w=%0d addr=%0d rgb=%06h | exp sx=%0d a3=%0d addr=%0d rgb=%06h  %0s",
                         cx_o - H_START_1X, cx_o,
                         sx_1x, a3_1x, wgt_1x, raddr_1x, rgb_1x,
                         m_sx, m_a3, m_addr, m_rgb,
                         ({sx_1x, a3_1x, raddr_1x, rgb_1x} ===
                          {m_sx,  m_a3,  m_addr,  m_rgb}) ? "ok" : "MISMATCH");
            end
        end

        // `de` 在 720 行以上绝不应该有效（V_START = 0，无上下黑边）
        // `de` must never be high below line 720 (V_START = 0, no bottom bars)
        if (pix_run && de && (cy_o >= V_ACTIVE)) de_below_err = de_below_err + 1;
    end

    // ------------------------------------------------------------------
    // 报告辅助 / reporting helpers
    // ------------------------------------------------------------------
    task report_point;
        input [8*40:1] label;
        input integer  mode43;
        input [11:0]   px;
        input [11:0]   py;
        input [23:0]   got;
        input          seen;
        reg [23:0] exp;
        integer sxi, a3i, wi;
        begin
            model(mode43, px, py);
            exp = m_rgb;
            named_checks = named_checks + 1;
            checks       = checks + 1;
            if (!seen) begin
                errors = errors + 1;
                $display("    FAIL  %0s px(%0d,%0d) never observed", label, px, py);
            end else if (got !== exp) begin
                errors = errors + 1;
                $display("    FAIL  %0s px(%0d,%0d) rgb %06h  expected %06h",
                         label, px, py, got, exp);
            end else begin
                $display("    PASS  %0s px(%0d,%0d) src(%0d,%0d) a3=%0d w=%0d ph%0d  rgb %06h",
                         label, px, py, m_sx, (py - V_START) / 3, m_a3, m_wgt,
                         (py - V_START) % 3, got);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // 激励 / stimulus
    // ------------------------------------------------------------------
    task pal_write;
        input [7:0] addr;
        input [5:0] val;
        begin
            cpu_cs_n = 1'b0; cpu_rw = 1'b0; cpu_a = 3'b110; cpu_d_in = 8'h3F;
            repeat (2) @(posedge clk_ppu);
            cpu_cs_n = 1'b1;
            repeat (2) @(posedge clk_ppu);
            cpu_cs_n = 1'b0; cpu_a = 3'b110; cpu_d_in = addr;
            repeat (2) @(posedge clk_ppu);
            cpu_cs_n = 1'b1;
            repeat (2) @(posedge clk_ppu);
            cpu_cs_n = 1'b0; cpu_a = 3'b111; cpu_d_in = {2'b00, val};
            repeat (2) @(posedge clk_ppu);
            cpu_cs_n = 1'b1;
            repeat (2) @(posedge clk_ppu);
        end
    endtask

    integer a, f, n;
    integer jj, cc;
    integer cnts [0:255];
    reg [7:0] xb, yb;
    reg [5:0] exp_fb;
    reg [23:0] exp1;
    integer sa_model_err;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("ppu_hdmi_720p.vcd");
            $dumpvars(0, tb_ppu_hdmi_720p);
        end

        $display("================================================================");
        $display(" PPU capture -> framebuffer -> 720p60 scaler -> HDMI  test");
        $display(" PPU dot clock 186.24 ns (5.369 MHz), video clock 13.468 ns (74.25 MHz)");
        $display(" 720p60 raster 1650x750 (60.000 Hz); active 1280x720");
        $display(" picture 960x720 (4:3, 3x+1.25x sharp bilinear) / 1024x720 (1:1, 4x)");
        $display("================================================================");

        // ---- 复位 / reset ----
        rst_n = 1'b0;
        repeat (20) @(posedge clk_ppu);
        rst_n = 1'b1;
        repeat (4) @(posedge clk_ppu);

        // ---- 通过 CPU 寄存器总线写入调色板 RAM 内容 ----
        // ---- palette RAM contents through the CPU register bus ----
        $display("\n=== PHASE 1: program palette shadow via $2006/$2007 ===");
        for (a = 0; a < 32; a = a + 1)
            pal_write(a[7:0], pal_code(a[4:0]));
        $display("  wrote 32 palette entries ($3F00-$3F1F)");

        // ---- 三个完整的源帧 / three complete source frames ----
        $display("  driving 3 source frames: 341x262 dots, 256x240 active, EXT pattern");
        for (f = 0; f < 3; f = f + 1)
            repeat (LINE_DOTS * N_LINES) @(posedge clk_ppu);

        // ---- 校验每一个帧缓冲表项 / verify every framebuffer entry ----
        $display("  checking framebuffer contents (256 x 240 entries, both instances) ...");
        for (n = 0; n < 256*240; n = n + 1) begin
            xb = n % 256;
            yb = (n / 256) % 256;
            exp_fb = pal_code(src_addr(xb, yb));
            if (u_vid_1x.u_fb.mem[n] !== exp_fb) begin
                errors = errors + 1;
                if (shown < 20) begin
                    $display("    FAIL  fb1x[%0d] = %02h, expected %02h", n,
                             u_vid_1x.u_fb.mem[n], exp_fb);
                    shown = shown + 1;
                end
            end
            if (u_vid_43.u_fb.mem[n] !== exp_fb) begin
                errors = errors + 1;
                if (shown < 20) begin
                    $display("    FAIL  fb43[%0d] = %02h, expected %02h", n,
                             u_vid_43.u_fb.mem[n], exp_fb);
                    shown = shown + 1;
                end
            end
            fb_checks = fb_checks + 1;
            checks    = checks + 2;
        end
        $display("  framebuffer: %0d entries checked (1:1 and 4:3 instances)", fb_checks);

        // ---- stage A 的整数重复：纯算术自检（不依赖 DUT）----
        // ---- stage A integer repeat: arithmetic self-check (independent of DUT) ----
        $display("\n=== PHASE 1b: stage-A integer-repeat model (256 columns -> 768 samples) ===");
        for (jj = 0; jj < 256; jj = jj + 1) cnts[jj] = 0;
        sa_model_err = 0;
        // 4:3: 输出列 i=0..959 的 stage-A 位置 j = floor(4i/5)，源列 = floor(j/3)
        // 4:3: stage-A position j = floor(4i/5) for i = 0..959, source = floor(j/3)
        for (jj = 0; jj < 960; jj = jj + 1) begin
            cc = (4*jj)/5;
            if (cc > 767) sa_model_err = sa_model_err + 1;
            if (jj > 0) begin
                if ((cc < ((4*(jj-1))/5)) || (cc > ((4*(jj-1))/5) + 1))
                    sa_model_err = sa_model_err + 1;
            end
        end
        // 遍历 stage-A 采样点 j = 0..767，每个源列必须正好 3 次
        // walk the stage-A samples j = 0..767; every source column exactly 3x
        for (jj = 0; jj < 768; jj = jj + 1)
            cnts[jj/3] = cnts[jj/3] + 1;
        for (jj = 0; jj < 256; jj = jj + 1)
            if (cnts[jj] != 3) sa_model_err = sa_model_err + 1;
        // 1:1: 1024 个采样点，每个源列正好 4 次
        // 1:1: 1024 samples, every source column exactly 4x
        for (jj = 0; jj < 256; jj = jj + 1) cnts[jj] = 0;
        for (jj = 0; jj < 1024; jj = jj + 1)
            cnts[jj/4] = cnts[jj/4] + 1;
        for (jj = 0; jj < 256; jj = jj + 1)
            if (cnts[jj] != 4) sa_model_err = sa_model_err + 1;

        checks = checks + 1;
        sa_checks = sa_checks + 1;
        if (sa_model_err == 0)
            $display("    PASS  stage A: 768 = 256 x 3 (4:3), 1024 = 256 x 4 (1:1), j monotone");
        else begin
            errors = errors + 1;
            $display("    FAIL  stage-A model: %0d violations", sa_model_err);
        end

        // 停止 PPU 时钟；此时帧缓冲里已有一整帧数据
        // stop the PPU clock; the framebuffer now holds one complete frame
        ppu_run = 1'b0;
        #1000;

        // ---- 一个完整的视频帧 / one complete video frame ----
        $display("\n=== PHASE 2: read out one 1650x750 (720p60) video frame ===");
        pix_run = 1'b1;
        repeat (8) @(posedge clk_pix);
        vid_rst = 1'b0;

        repeat (V_FRAME_CLKS) @(posedge clk_pix);
        pix_run = 1'b0;

        // ---- 画面矩形 / picture rectangle ----
        $display("\n---- picture rectangle (whole-row census on row 360) ----");
        checks = checks + 5;
        if (wcnt43 == 960 && wfirst43 == H_START_43 && wlast43 == (H_START_43+959)) begin
            $display("    PASS  [4:3] picture columns %0d..%0d, width %0d (bars %0d px each side)",
                     wfirst43, wlast43, wcnt43, H_START_43);
        end else begin
            errors = errors + 1;
            $display("    FAIL  [4:3] picture columns %0d..%0d, width %0d (expected %0d..%0d, width 960)",
                     wfirst43, wlast43, wcnt43, H_START_43, H_START_43+959);
        end
        if (wcnt1x == 1024 && wfirst1x == H_START_1X && wlast1x == (H_START_1X+1023)) begin
            $display("    PASS  [1:1] picture columns %0d..%0d, width %0d (bars %0d px each side)",
                     wfirst1x, wlast1x, wcnt1x, H_START_1X);
        end else begin
            errors = errors + 1;
            $display("    FAIL  [1:1] picture columns %0d..%0d, width %0d (expected %0d..%0d, width 1024)",
                     wfirst1x, wlast1x, wcnt1x, H_START_1X, H_START_1X+1023);
        end
        if (vcnt43 == 720 && vcnt1x == 720 && de_below_err == 0) begin
            $display("    PASS  vertical: 720 picture rows in both modes, 0 rows with de below y=720");
        end else begin
            errors = errors + 1;
            $display("    FAIL  vertical: 4:3 rows %0d, 1:1 rows %0d, de-below-720 %0d",
                     vcnt43, vcnt1x, de_below_err);
        end

        // ---- stage-A 跟踪结果（由 DUT 观测）/ stage-A tracker results (from the DUT) ----
        $display("\n---- stage A observed on row 0 (DUT) ----");
        checks = checks + 3;
        if (sa_steps43 == 767 && sa_sxinc43 == 255 && sa_err43 == 0) begin
            $display("    PASS  [4:3] %0d stage-A steps, %0d source-column increments, phase 0,1,2 strict",
                     sa_steps43, sa_sxinc43);
        end else begin
            errors = errors + 1;
            $display("    FAIL  [4:3] steps %0d (exp 767), sx incs %0d (exp 255), order errors %0d",
                     sa_steps43, sa_sxinc43, sa_err43);
        end
        if (sa_steps1x == 1023 && sa_sxinc1x == 255 && sa_err1x == 0) begin
            $display("    PASS  [1:1] %0d stage-A steps, %0d source-column increments, phase 0,1,2,3 strict",
                     sa_steps1x, sa_sxinc1x);
        end else begin
            errors = errors + 1;
            $display("    FAIL  [1:1] steps %0d (exp 1023), sx incs %0d (exp 255), order errors %0d",
                     sa_steps1x, sa_sxinc1x, sa_err1x);
        end
        $display("    PASS  4:3 = 768 stage-A samples over 960 output columns (4 of every 5 columns)");
        sa_checks = sa_checks + 3;
        checks    = checks + 3;

        // ---- 命名点报告 / named point report ----
        $display("\n---- 4:3 mode: 960x720, h_start 160, v_start 0, 3x + 1.25x sharp bilinear ----");
        report_point("bar before TL  ", 1, H_START_43-1,        12'd0,   cap43[0],  seen43[0]);
        report_point("picture TL     ", 1, H_START_43,          12'd0,   cap43[1],  seen43[1]);
        report_point("scanline ph1   ", 1, H_START_43,          12'd1,   cap43[2],  seen43[2]);
        report_point("scanline ph2 0%", 1, H_START_43,          12'd2,   cap43[3],  seen43[3]);
        report_point("next line ph0  ", 1, H_START_43,          12'd3,   cap43[4],  seen43[4]);
        report_point("left edge y360 ", 1, H_START_43,          12'd360, cap43[5],  seen43[5]);
        report_point("picture TR     ", 1, H_START_43+959,      12'd0,   cap43[6],  seen43[6]);
        report_point("picture BR     ", 1, H_START_43+959,      12'd717, cap43[7],  seen43[7]);
        report_point("bar after TR   ", 1, H_START_43+960,      12'd0,   cap43[8],  seen43[8]);
        report_point("scanline ph0   ", 1, 12'd400,             12'd0,   cap43[9],  seen43[9]);
        report_point("scanline ph1   ", 1, 12'd400,             12'd1,   cap43[10], seen43[10]);
        report_point("scanline ph2 0%", 1, 12'd400,             12'd2,   cap43[11], seen43[11]);
        report_point("blend column   ", 1, 12'd639,             12'd360, cap43[12], seen43[12]);

        $display("\n---- 1:1 mode: 1024x720, h_start 128, v_start 0, 4x ----");
        report_point("bar before TL  ", 0, H_START_1X-1,        12'd0,   cap1x[0],  seen1x[0]);
        report_point("picture TL     ", 0, H_START_1X,          12'd0,   cap1x[1],  seen1x[1]);
        report_point("scanline ph1   ", 0, H_START_1X,          12'd1,   cap1x[2],  seen1x[2]);
        report_point("scanline ph2 0%", 0, H_START_1X,          12'd2,   cap1x[3],  seen1x[3]);
        report_point("next line ph0  ", 0, H_START_1X,          12'd3,   cap1x[4],  seen1x[4]);
        report_point("bottom-left    ", 0, H_START_1X,          12'd719, cap1x[5],  seen1x[5]);
        report_point("4x repeat col 3", 0, H_START_1X+3,        12'd0,   cap1x[6],  seen1x[6]);
        report_point("4x repeat col 4", 0, H_START_1X+4,        12'd0,   cap1x[7],  seen1x[7]);
        report_point("picture TR     ", 0, H_START_1X+1023,     12'd0,   cap1x[8],  seen1x[8]);
        report_point("bar after TR   ", 0, H_START_1X+1024,     12'd0,   cap1x[9],  seen1x[9]);
        report_point("scanline ph0   ", 0, 12'd400,             12'd0,   cap1x[10], seen1x[10]);
        report_point("scanline ph1   ", 0, 12'd400,             12'd1,   cap1x[11], seen1x[11]);
        report_point("scanline ph2 0%", 0, 12'd400,             12'd2,   cap1x[12], seen1x[12]);
        report_point("centre pixel   ", 0, 12'd639,             12'd360, cap1x[13], seen1x[13]);

        // ---- 汇总 / summary ----
        $display("\n================================================================");
        $display(" framebuffer entry checks : %0d", fb_checks);
        $display(" swept pixel checks       : %0d", pix_checks);
        $display(" stage-A / geometry checks: %0d", sa_checks);
        $display(" named point checks       : %0d", named_checks);
        $display(" total checks             : %0d", checks);
        $display(" errors                   : %0d", errors);
        if (errors == 0)
            $display(" RESULT: PASS");
        else
            $display(" RESULT: FAIL");
        $display("================================================================");
        $finish;
    end

    initial begin
        #400_000_000;   // 400 ms watchdog
        $display("WATCHDOG TIMEOUT");
        $finish;
    end

endmodule
