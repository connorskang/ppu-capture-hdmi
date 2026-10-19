// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// tb_ppu_hdmi.v -- PPU -> HDMI 集成通路的自检 testbench。
// tb_ppu_hdmi.v -- self-checking testbench for the integrated PPU -> HDMI path.
//
//   PPU 光栅 + 调色板写  ->  ppu_capture_intercept  ->  帧缓冲
//        ->  ppu_video_pipeline (1:1 4x)      -> rgb  --\
//        ->  ppu_video_pipeline (4:3  1280)   -> rgb  ----> 被检查
//   PPU raster + palette writes  ->  ppu_capture_intercept  ->  framebuffer
//        ->  ppu_video_pipeline (1:1 4x)      -> rgb  --\
//        ->  ppu_video_pipeline (4:3  1280)   -> rgb  ----> checked
//
// 第 1 阶段（PPU 像素时钟，5.369 MHz）：通过 CPU 寄存器总线编程调色板，在
//   EXT0..3 + EXT4 以及比较器时序输入上驱动三个完整的 NTSC 形状源帧
//   （341 点 x 262 行，有效区 256x240）的已知图案，然后逐条校验全部 61440 个
//   帧缓冲表项与期望的调色板表项是否一致。
// 第 2 阶段（视频像素时钟，74.25 MHz）：一个完整的 2200x1125 1080p 帧。
//   每个被采样的输出像素都会与一个独立的黄金模型比较（直接除法，而不是 DUT
//   的 Bresenham 累加器），另外还有一张命名点表（画面四角、中心、边框、
//   扫描线相位）。
// Phase 1 (PPU pixel clock, 5.369 MHz): program the palette through the CPU
//   register bus, drive three complete NTSC-shaped source frames (341 dots x
//   262 lines, 256x240 active) of a known pattern on EXT0..3 + EXT4 and the
//   comparator timing inputs, then verify EVERY ONE of the 61440 framebuffer
//   entries against the expected palette entry.
// Phase 2 (video pixel clock, 74.25 MHz): one complete 2200x1125 1080p frame.
//   Every sampled output pixel is compared against an independent golden model
//   (direct division, not the DUT's Bresenham accumulator), plus a table of
//   named points (picture corners, centre, borders, scanline phases).
//
// testbench 通过层次化引用读取 DUT 的两条内部网络（`u_vid_1x.raddr` 与
// `u_vid_1x.phase`），这样检查缩放器时针对的是它实际取到的源地址，而不仅仅是
// 它产生的颜色。这些网络都是流水线的纯组合产物；没有任何强制赋值。
// The testbench reads two internal DUT nets through hierarchical references
// (`u_vid_1x.raddr` and `u_vid_1x.phase`) so that the scaler is checked on the
// exact source address it fetched, not merely on the colour it produced.  Those
// nets are pure combinational products of the pipeline; nothing is forced.
//
// 运行方式：见 sim/run.ps1。在 vvp 命令行加 +vcd 可导出波形。
// Run: see sim/run.ps1.  Add +vcd on the vvp command line for a waveform.
// -----------------------------------------------------------------------------

module tb_ppu_hdmi;

    // ------------------------------------------------------------------
    // 被测设计的几何常数 / Geometry constants of the design under test
    // ------------------------------------------------------------------
    localparam [11:0] H_ACTIVE = 12'd1920;
    localparam [11:0] V_ACTIVE = 12'd1080;
    localparam [11:0] H_TOTAL  = 12'd2200;
    localparam [11:0] V_TOTAL  = 12'd1125;

    localparam integer V_START    = 60;   // (1080-960)/2
    localparam integer PIC_H      = 960;
    localparam integer H_START_1X = 448;  // (1920-1024)/2
    localparam integer H_START_43 = 320;  // (1920-1280)/2

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

    localparam integer V_FRAME_CLKS = 2200 * 1125;

    // ------------------------------------------------------------------
    // 时钟（带门控：每个发生器只在使能为高时推进）
    // Clocks (gated: each generator only advances while its enable is high)
    // ------------------------------------------------------------------
    reg clk_ppu = 1'b0;      // 186.24 ns -> 5.369 MHz (2C02 dot clock)
    reg clk_pix = 1'b0;      //  13.468 ns -> 74.25 MHz (1080p pixel clock)
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

    wire [7:0]  cpu_d_out;
    wire        cpu_d_oe;

    // ------------------------------------------------------------------
    // 黄金模型：源图案 -> 调色板地址 / Golden model: source pattern -> palette address
    // ------------------------------------------------------------------
    // 源像素 (x,y) 的 5 位调色板地址：
    // 5-bit palette address for source pixel (x,y):
    //     { x[7], y[7], x[1], 1'b1, x[0] }
    // bit 1 恒为 1，因此该地址永远不会落在四个通用背景色镜像
    // （$3F10/$14/$18/$1C）上 —— 它们的 bits[1:0] == 2'b00，会被影子映射到
    // $3F00/$04/$08/$0C。因此该图案只覆盖 8 个不同的调色板表项。
    // Bit 1 is constant 1, so the address can never be one of the four
    // universal-backdrop mirrors ($3F10/$14/$18/$1C), which all have
    // bits[1:0] == 2'b00 and are remapped by the shadow onto $3F00/$04/$08/$0C.
    // The pattern therefore exercises 8 distinct palette entries.
    function [4:0] src_addr;
        input [7:0] x;
        input [7:0] y;
        begin
            src_addr = {x[7], y[7], x[1], 1'b1, x[0]};
        end
    endfunction

    // 写入调色板表项 `a` 的值。配合上面的图案，有效索引是
    // {a[4], a[3], a[1], a[0]} = {x[7], y[7], 1, x[0]}，因此该表就按这四位索引。
    // Value written into palette entry `a`.  With the pattern above the
    // effective index is {a[4], a[3], a[1], a[0]} = {x[7], y[7], 1, x[0]}, so
    // the table is indexed by those four bits.
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

    // 相位 0..3 的扫描线亮度，单位 1/256。/ Scanline level for phase 0..3, in 1/256 units.
    function integer lvl_of;
        input integer ph;
        begin
            case (ph)
                0: lvl_of = 256;
                1: lvl_of = 256;
                2: lvl_of = 128;
                default: lvl_of = 0;
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

    // ------------------------------------------------------------------
    // 黄金几何：返回 {in_pic, src_addr[15:0], phase[1:0]}
    // Golden geometry: returns {in_pic, src_addr[15:0], phase[1:0]}
    // ------------------------------------------------------------------
    function [18:0] geom;
        input integer mode43;
        input [11:0] x;
        input [11:0] y;
        integer hout, hstart, i, sx, j;
        reg [15:0] a16;
        reg [1:0]  p2;
        begin
            if (mode43) begin
                hout   = 1280;
                hstart = H_START_43;
            end else begin
                hout   = 1024;
                hstart = H_START_1X;
            end

            if ((x < hstart) || (x >= (hstart + hout)) ||
                (y < V_START) || (y >= (V_START + PIC_H)))
                geom = {1'b0, 16'd0, 2'd0};
            else begin
                i   = x - hstart;
                sx  = (i * 256) / hout;
                j   = y - V_START;
                a16 = (j / 4) * 256 + sx;
                p2  = j % 4;
                geom = {1'b1, a16, p2};
            end
        end
    endfunction

    function [23:0] rgb_model;
        input        in_pic;
        input [15:0] addr;
        input [1:0]  ph;
        reg [7:0] xb, yb;
        reg [5:0] code;
        begin
            if (!in_pic)
                rgb_model = BORDER;
            else begin
                xb   = addr % 256;
                yb   = addr / 256;
                code = pal_code(src_addr(xb, yb));
                rgb_model = {dim8(pal_rgb_model(code) >> 16,           lvl_of(ph)),
                             dim8((pal_rgb_model(code) >> 8) & 8'hff,  lvl_of(ph)),
                             dim8(pal_rgb_model(code) & 8'hff,         lvl_of(ph))};
            end
        end
    endfunction

    // 做 100% 穷举水平扫描的行。/ Rows that get a 100 % exhaustive horizontal sweep.
    function is_sweep_row;
        input [11:0] y;
        begin
            case (y)
                12'd0, 12'd59, 12'd60, 12'd61, 12'd62, 12'd63, 12'd64, 12'd65,
                12'd120, 12'd300, 12'd539, 12'd540, 12'd541, 12'd542, 12'd543,
                12'd700, 12'd900,
                12'd1016, 12'd1017, 12'd1018, 12'd1019, 12'd1020,
                12'd1079: is_sweep_row = 1'b1;
                default:  is_sweep_row = 1'b0;
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
    // DUT：两条视频流水线，1:1（4 倍，1024）与 4:3（5 倍，1280），共用同一份源数据
    // DUT: two video pipelines, 1:1 (4x, 1024) and 4:3 (5x, 1280), same source data
    // ------------------------------------------------------------------
    ppu_video_pipeline #(
        .H_ACTIVE (H_ACTIVE), .V_ACTIVE (V_ACTIVE)
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
        .cy_o      (cy_o)
    );

    ppu_video_pipeline #(
        .H_ACTIVE (H_ACTIVE), .V_ACTIVE (V_ACTIVE)
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
        .cy_o      ()
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
    // 检查器 / Checkers
    // ------------------------------------------------------------------
    integer checks = 0;
    integer errors = 0;
    integer shown  = 0;

    integer sweep_checks = 0;
    integer named_checks = 0;
    integer fb_checks    = 0;

    // DUT 取址地址 / 相位的流水线副本，以便与 `rgb` 在同一时刻（2 个时钟后）
    // 进行比较。
    // pipelined copies of the DUT's fetch address / phase so that they can be
    // compared at the same time as `rgb` (2 clocks later)
    reg [15:0] raddr_q0, raddr_q1;      // 1:1 instance
    reg [15:0] raddr43_q0, raddr43_q1;  // 4:3 instance
    reg [1:0]  phase_q0, phase_q1;

    always @(posedge clk_pix) begin
        raddr_q0   <= u_vid_1x.raddr;
        raddr_q1   <= raddr_q0;
        raddr43_q0 <= u_vid_43.raddr;
        raddr43_q1 <= raddr43_q0;
        phase_q0   <= u_vid_1x.phase;
        phase_q1   <= phase_q0;
    end

    // 命名点捕获 / named-point capture
    reg [23:0] cap_1x [0:12];
    reg [23:0] cap_43 [0:10];
    reg        seen_1x [0:12];
    reg        seen_43 [0:10];

    integer k;
    initial begin
        for (k = 0; k < 13; k = k + 1) seen_1x[k] = 1'b0;
        for (k = 0; k < 11; k = k + 1) seen_43[k] = 1'b0;
    end

    reg [18:0] g1, g43;
    reg [23:0] exp1, exp43;
    reg        named_row;

    always @(posedge clk_pix) begin
        if (pix_run && de) begin
            g1  = geom(0, cx_o, cy_o);
            g43 = geom(1, cx_o, cy_o);

            if (is_sweep_row(cy_o) || (cx_o[8:0] == 9'd0)) begin
                // ---- 精确的源地址 + 扫描线相位 / exact source address + scanline phase ----
                if (g1[18] && (raddr_q1 !== g1[17:2])) begin
                    errors = errors + 1;
                    if (shown < 20) begin
                        $display("    FAIL  [1x]  (%0d,%0d) fetch addr %0d, expected %0d",
                                 cx_o, cy_o, raddr_q1, g1[17:2]);
                        shown = shown + 1;
                    end
                end
                if (g43[18] && (raddr43_q1 !== g43[17:2])) begin
                    errors = errors + 1;
                    if (shown < 20) begin
                        $display("    FAIL  [4:3] (%0d,%0d) fetch addr %0d, expected %0d",
                                 cx_o, cy_o, raddr43_q1, g43[17:2]);
                        shown = shown + 1;
                    end
                end
                if (g1[18] && (phase_q1 !== g1[1:0])) begin
                    errors = errors + 1;
                    if (shown < 20) begin
                        $display("    FAIL  [1x]  (%0d,%0d) phase %0d, expected %0d",
                                 cx_o, cy_o, phase_q1, g1[1:0]);
                        shown = shown + 1;
                    end
                end

                // ---- RGB ----
                exp1 = rgb_model(g1[18], g1[17:2], g1[1:0]);
                if (rgb_1x !== exp1) begin
                    errors = errors + 1;
                    if (shown < 20) begin
                        $display("    FAIL  [1x]  (%0d,%0d) rgb %06h, expected %06h",
                                 cx_o, cy_o, rgb_1x, exp1);
                        shown = shown + 1;
                    end
                end
                checks = checks + 1;
                sweep_checks = sweep_checks + 1;

                exp43 = rgb_model(g43[18], g43[17:2], g43[1:0]);
                if (rgb_43 !== exp43) begin
                    errors = errors + 1;
                    if (shown < 20) begin
                        $display("    FAIL  [4:3] (%0d,%0d) rgb %06h, expected %06h",
                                 cx_o, cy_o, rgb_43, exp43);
                        shown = shown + 1;
                    end
                end
                checks = checks + 1;
                sweep_checks = sweep_checks + 1;
            end

            // ---- 命名点（每种模式单独一个 case：重复的 case 项只会执行第一个
            //      匹配项）
            // ---- named points (separate case per mode: duplicate case items
            //      would only execute the first match) ----
            named_row = (cy_o == 12'd540) || (cy_o == 12'd20)  ||
                        (cy_o == 12'd60)  || (cy_o == 12'd61) ||
                        (cy_o == 12'd62)  || (cy_o == 12'd63) ||
                        (cy_o == 12'd64)  || (cy_o == 12'd1019);
            if (named_row) begin
            case ({cx_o, cy_o})
                {12'd200,  12'd540}:  begin cap_1x[0]  = rgb_1x; seen_1x[0]  = 1'b1; end
                {12'd960,  12'd20}:   begin cap_1x[1]  = rgb_1x; seen_1x[1]  = 1'b1; end
                {12'd448,  12'd60}:   begin cap_1x[2]  = rgb_1x; seen_1x[2]  = 1'b1; end
                {12'd451,  12'd60}:   begin cap_1x[3]  = rgb_1x; seen_1x[3]  = 1'b1; end
                {12'd452,  12'd60}:   begin cap_1x[4]  = rgb_1x; seen_1x[4]  = 1'b1; end
                {12'd960,  12'd540}:  begin cap_1x[5]  = rgb_1x; seen_1x[5]  = 1'b1; end
                {12'd1471, 12'd1019}: begin cap_1x[6]  = rgb_1x; seen_1x[6]  = 1'b1; end
                {12'd960,  12'd61}:   begin cap_1x[7]  = rgb_1x; seen_1x[7]  = 1'b1; end
                {12'd960,  12'd62}:   begin cap_1x[8]  = rgb_1x; seen_1x[8]  = 1'b1; end
                {12'd960,  12'd63}:   begin cap_1x[9]  = rgb_1x; seen_1x[9]  = 1'b1; end
                {12'd960,  12'd64}:   begin cap_1x[10] = rgb_1x; seen_1x[10] = 1'b1; end
                {12'd1471, 12'd60}:   begin cap_1x[11] = rgb_1x; seen_1x[11] = 1'b1; end
                {12'd1472, 12'd60}:   begin cap_1x[12] = rgb_1x; seen_1x[12] = 1'b1; end
                default: ;
            endcase

            case ({cx_o, cy_o})
                {12'd100,  12'd540}:  begin cap_43[0] = rgb_43; seen_43[0] = 1'b1; end
                {12'd320,  12'd60}:   begin cap_43[1] = rgb_43; seen_43[1] = 1'b1; end
                {12'd960,  12'd540}:  begin cap_43[2] = rgb_43; seen_43[2] = 1'b1; end
                {12'd1599, 12'd1019}: begin cap_43[3] = rgb_43; seen_43[3] = 1'b1; end
                {12'd960,  12'd62}:   begin cap_43[4] = rgb_43; seen_43[4] = 1'b1; end
                {12'd1000, 12'd60}:   begin cap_43[5] = rgb_43; seen_43[5] = 1'b1; end
                {12'd700,  12'd60}:   begin cap_43[6] = rgb_43; seen_43[6] = 1'b1; end
                {12'd319,  12'd60}:   begin cap_43[7] = rgb_43; seen_43[7] = 1'b1; end
                {12'd324,  12'd60}:   begin cap_43[8] = rgb_43; seen_43[8] = 1'b1; end
                {12'd325,  12'd60}:   begin cap_43[9] = rgb_43; seen_43[9] = 1'b1; end
                {12'd1600, 12'd60}:   begin cap_43[10] = rgb_43; seen_43[10] = 1'b1; end
                default: ;
            endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // 报告辅助 / Reporting helpers
    // ------------------------------------------------------------------
    task report_point;
        input [8*40:1] label;
        input integer  mode43;
        input [11:0]   px;
        input [11:0]   py;
        input [23:0]   got;
        input          seen;
        reg [18:0] g;
        reg [23:0] exp;
        begin
            g   = geom(mode43, px, py);
            exp = rgb_model(g[18], g[17:2], g[1:0]);
            named_checks = named_checks + 1;
            checks       = checks + 1;
            if (!seen) begin
                errors = errors + 1;
                $display("    FAIL  %0s px(%0d,%0d) never observed", label, px, py);
            end else if (got !== exp) begin
                errors = errors + 1;
                $display("    FAIL  %0s px(%0d,%0d) src(%0d,%0d) ph%0d  rgb %06h  expected %06h",
                         label, px, py, g[17:2] % 256, g[17:2] / 256, g[1:0], got, exp);
            end else begin
                $display("    PASS  %0s px(%0d,%0d) src(%0d,%0d) ph%0d  rgb %06h",
                         label, px, py, g[17:2] % 256, g[17:2] / 256, g[1:0], got);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // 激励 / Stimulus
    // ------------------------------------------------------------------
    task pal_write;
        input [7:0] addr;
        input [5:0] val;
        begin
            // $2006 = 0x3F（调色板区高字节）/ $2006 = 0x3F
            cpu_cs_n = 1'b0; cpu_rw = 1'b0; cpu_a = 3'b110; cpu_d_in = 8'h3F;
            repeat (2) @(posedge clk_ppu);
            cpu_cs_n = 1'b1;
            repeat (2) @(posedge clk_ppu);
            // $2006 = 地址 / $2006 = addr
            cpu_cs_n = 1'b0; cpu_a = 3'b110; cpu_d_in = addr;
            repeat (2) @(posedge clk_ppu);
            cpu_cs_n = 1'b1;
            repeat (2) @(posedge clk_ppu);
            // $2007 = 数据 / $2007 = val
            cpu_cs_n = 1'b0; cpu_a = 3'b111; cpu_d_in = {2'b00, val};
            repeat (2) @(posedge clk_ppu);
            cpu_cs_n = 1'b1;
            repeat (2) @(posedge clk_ppu);
        end
    endtask

    integer a, f, n;
    reg [7:0] xb, yb;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("ppu_hdmi.vcd");
            $dumpvars(0, tb_ppu_hdmi);
        end

        $display("================================================================");
        $display(" PPU capture -> framebuffer -> scaler -> HDMI  integration test");
        $display(" PPU dot clock 186.24 ns (5.369 MHz), video clock 13.468 ns (74.25 MHz)");
        $display(" 1080p30 raster 2200x1125; picture 1024x960 (1:1, 4x) / 1280x960 (4:3, 5x)");
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
            exp1 = {18'h0, pal_code(src_addr(xb, yb))};
            if (u_vid_1x.u_fb.mem[n] !== exp1[5:0]) begin
                errors = errors + 1;
                if (shown < 20) begin
                    $display("    FAIL  fb1[%0d] = %02h, expected %02h", n,
                             u_vid_1x.u_fb.mem[n], exp1[5:0]);
                    shown = shown + 1;
                end
            end
            if (u_vid_43.u_fb.mem[n] !== exp1[5:0]) begin
                errors = errors + 1;
                if (shown < 20) begin
                    $display("    FAIL  fb43[%0d] = %02h, expected %02h", n,
                             u_vid_43.u_fb.mem[n], exp1[5:0]);
                    shown = shown + 1;
                end
            end
            fb_checks = fb_checks + 1;
            checks    = checks + 2;
        end
        $display("  framebuffer: %0d entries checked (1:1 and 4:3 instances)", fb_checks);

        // 停止 PPU 时钟；此时帧缓冲里已有一整帧数据
        // stop the PPU clock; the framebuffer now holds one complete frame
        ppu_run = 1'b0;
        #1000;   // let any in-flight clock half-cycle finish

        // ---- 一个完整的视频帧 / one complete video frame ----
        $display("\n=== PHASE 2: read out one 2200x1125 (1080p30) video frame ===");
        pix_run = 1'b1;
        repeat (8) @(posedge clk_pix);
        vid_rst = 1'b0;

        repeat (V_FRAME_CLKS) @(posedge clk_pix);
        pix_run = 1'b0;

        // ---- 命名点报告 / named point report ----
        $display("\n---- 1:1 mode: 4x exact, 256 -> 1024, h_start 448, v_start 60 ----");
        report_point("border left     ", 0, 12'd200,  12'd540,  cap_1x[0],  seen_1x[0]);
        report_point("border top      ", 0, 12'd960,  12'd20,   cap_1x[1],  seen_1x[1]);
        report_point("picture TL      ", 0, 12'd448,  12'd60,   cap_1x[2],  seen_1x[2]);
        report_point("4x repeat col 3 ", 0, 12'd451,  12'd60,   cap_1x[3],  seen_1x[3]);
        report_point("4x repeat col 4 ", 0, 12'd452,  12'd60,   cap_1x[4],  seen_1x[4]);
        report_point("centre pixel    ", 0, 12'd960,  12'd540,  cap_1x[5],  seen_1x[5]);
        report_point("picture BR      ", 0, 12'd1471, 12'd1019, cap_1x[6],  seen_1x[6]);
        report_point("scanline ph1    ", 0, 12'd960,  12'd61,   cap_1x[7],  seen_1x[7]);
        report_point("scanline ph2 50%", 0, 12'd960,  12'd62,   cap_1x[8],  seen_1x[8]);
        report_point("scanline ph3  0%", 0, 12'd960,  12'd63,   cap_1x[9],  seen_1x[9]);
        report_point("next line ph0   ", 0, 12'd960,  12'd64,   cap_1x[10], seen_1x[10]);
        report_point("picture TR      ", 0, 12'd1471, 12'd60,   cap_1x[11], seen_1x[11]);
        report_point("border right    ", 0, 12'd1472, 12'd60,   cap_1x[12], seen_1x[12]);

        $display("\n---- 4:3 mode: 5x exact, 256 -> 1280, h_start 320, v_start 60 ----");
        report_point("border left     ", 1, 12'd100,  12'd540,  cap_43[0], seen_43[0]);
        report_point("picture TL      ", 1, 12'd320,  12'd60,   cap_43[1], seen_43[1]);
        report_point("centre pixel    ", 1, 12'd960,  12'd540,  cap_43[2], seen_43[2]);
        report_point("picture BR      ", 1, 12'd1599, 12'd1019, cap_43[3], seen_43[3]);
        report_point("scanline ph2 50%", 1, 12'd960,  12'd62,   cap_43[4], seen_43[4]);
        report_point("5x col 1000     ", 1, 12'd1000, 12'd60,   cap_43[5], seen_43[5]);
        report_point("5x col 700      ", 1, 12'd700,  12'd60,   cap_43[6], seen_43[6]);
        report_point("border before TL", 1, 12'd319,  12'd60,   cap_43[7], seen_43[7]);
        report_point("5x repeat col 5 ", 1, 12'd324,  12'd60,   cap_43[8], seen_43[8]);
        report_point("5x repeat col 6 ", 1, 12'd325,  12'd60,   cap_43[9], seen_43[9]);
        report_point("border after BR ", 1, 12'd1600, 12'd60,   cap_43[10], seen_43[10]);

        // ---- 汇总 / summary ----
        $display("\n================================================================");
        $display(" framebuffer entry checks : %0d", fb_checks);
        $display(" swept pixel checks       : %0d", sweep_checks);
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
