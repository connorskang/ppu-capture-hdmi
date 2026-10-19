// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// ppu_video_pipeline_720p.v
//
// 720p60 读侧缩放流水线：256x240 帧缓冲 -> 3 倍垂直 + 扫描线明暗
//                       -> 水平 4:3（3 倍整数 + 768->960 锐利双线性）或 1:1（4 倍）
//                       -> NES 调色板 -> RGB -> 时序
// 720p60 read-side scaling pipeline: 256x240 framebuffer -> 3x vertical
//                       + scanline shading -> horizontal 4:3 (integer 3x then
//                       768->960 "sharp bilinear") or 1:1 (4x) -> NES palette
//                       -> RGB -> timing.
//
//   PPU 像素时钟域                   视频像素时钟域
//   PPU pixel clock domain            video pixel clock domain
//   ----------------------            -----------------------
//   pixel_index (6b) + valid  --->  [ 256x240x6 framebuffer ]  ---> scaler ---> RGB
//                                   (semi-dual-port BSRAM)
//
// ## 为什么另起一个模块，而不是改 1080p30 的那个
// ## Why a separate module instead of editing the 1080p30 one
// 1080p30 的 `ppu_video_pipeline.v` 保持**逐字节不变**，这样它那 219,694 项
// 检查的仿真结果与已验证的时序/资源指纹继续有效（REPORT.md §5）。720p60 需要
// 换垂直系数（4->3）、换扫描线相位数（4->3）、并且水平 4:3 从"整数 5 倍"变成
// "分数 1.25 倍"—— 结构不同，硬塞进同一个模块只会让两边都变难验证。
// The 1080p30 `ppu_video_pipeline.v` stays **byte-identical**, so its
// 219,694-check simulation result and its recorded timing/resource signature
// remain valid (REPORT.md §5).  720p60 changes the vertical factor (4 -> 3),
// the number of scanline phases (4 -> 3), and turns horizontal 4:3 from an
// integer 5x into a fractional 1.25x -- a different structure.  Forcing them
// into one module would make both harder to verify.
//
// ## 几何 / Geometry
//   H_OUT(4:3) = 960 = 720 * 4/3   -> 正好 4:3（720 行高时 960 宽）
//   H_OUT(4:3) = 960 = 720 * 4/3   -> exactly 4:3 (960 wide at 720 lines)
//   H_START(4:3) = (1280-960)/2 = 160  -> 左右各 160 px 黑边
//   H_START(4:3) = (1280-960)/2 = 160  -> 160 px pillarbox each side
//   H_OUT(1:1) = 1024 = 256 * 4    -> 方形像素（1:1）
//   H_OUT(1:1) = 1024 = 256 * 4    -> square pixels (1:1)
//   H_START(1:1) = (1280-1024)/2 = 128 -> 左右各 128 px 黑边
//   H_START(1:1) = (1280-1024)/2 = 128 -> 128 px pillarbox each side
//   V: 240 * 3 = 720 = V_ACTIVE   -> 上下黑边 = 0（画面占满 720 行）
//   V: 240 * 3 = 720 = V_ACTIVE   -> zero top/bottom bars (full 720 lines)
//
// 960/256 = 3.75，整数倍做不到 4:3；纯 Bresenham 会产生"有的源列 3 列、有的
// 4 列"的宽度不均。本模块按任务书用**两级**结构：
// 960/256 = 3.75, so no integer factor gives 4:3, and plain Bresenham produces
// the uneven-column artefact (some source columns 3 output px, some 4).  This
// module uses the two-stage structure the brief specifies:
//
//   第一级 / stage A: 256 -> 768，整数 3 倍最近邻。每个源像素正好变成 3 个
//                     相同的 stage-A 采样点，绝对均匀。
//                     integer 3x nearest: every source pixel becomes exactly
//                     three identical stage-A samples -- perfectly uniform.
//   第二级 / stage B: 768 -> 960（x1.25）。对输出列 i，stage-A 位置
//                     j = floor(4i/5)，f = frac(4i/5)：
//                     768 -> 960 (x1.25).  For output column i the stage-A
//                     position is j = floor(4i/5), f = frac(4i/5), and
//                       f < T_LO          -> 取左（stage-A 的 j）
//                       f > T_HI          -> 取右（stage-A 的 j+1）
//                       其它 / otherwise  -> 按 f 线性混合
//                     f 只取 5 个值 {0, 1/5, 2/5, 3/5, 4/5}，所以默认阈值
//                     T_LO=1/5、T_HI=4/5 时两个分支都不触发（严格不等号），
//                     混合权重就是 f 本身（1/256 定点 0/51/102/154/205）。
//                     f takes only the five values {0,1/5,2/5,3/5,4/5}, so with
//                     the default T_LO=1/5, T_HI=4/5 neither branch fires (the
//                     comparisons are strict) and the blend weight is f itself
//                     (0/51/102/154/205 in 1/256 units).
//
// 关键在于：stage A 的相邻两个采样点 A[j]、A[j+1] 在 j mod 3 != 2 时是**同一个
// 源像素**，混合结果与单像素完全相同 —— 于是"混合"只在源列边界那一列真正可见。
// 960 列里只有 256 列发生真正的混合（每个源列边界 1 列），其余 704 列
// (73.3%) 是纯粹的单源像素重复。这正是"消除 Bresenham 宽度不均"的效果：
// 边界不再是硬跳变，而是一列渐变。任务书里"约 90% 列保持锐利"的说法在这套
// 量化网格上做不到 —— 实测 73.3%，见 REPORT 的实测表。
// The point: stage-A neighbours A[j], A[j+1] are the *same source pixel*
// whenever j mod 3 != 2, so the blend is invisible there -- a real blend
// happens only on the column where a source-column boundary falls.  Exactly 256
// of the 960 columns are genuinely mixed (one per source-column boundary) and
// the other 704 (73.3 %) are pure single-pixel repeats.  That is the artefact
// removal: the boundary becomes one interpolated column instead of a hard jump.
// The brief's "~90 % of columns stay sharp" is not reachable on this quantised
// 5-phase lattice; the measured figure is 73.3 % (see REPORT).
//
// ## 读取结构（单读端口 + 一次寄存器）/ Read structure (one read port)
// 帧缓冲是半双端口的，只有**一个**读端口，但混合需要同时看到相邻两个 tap。
// 这里利用地址序列单调的性质：
//   raddr = sy*256 + M(i),  M(i) = s(i) + (a3(i)==2 ? 1 : 0)
// 读延迟 1 个时钟，于是在第 i+1 个时钟：fb_q = src[M(i)]，再打一拍得
// src[M(i-1)]。另外用一个 `hsrc` 寄存器记住"最近一次 a3 != 2 的列取到的
// 源像素"，它就等于 src[s(i)]。于是
//   idx_left  = a3==2 ? hsrc : fb_q      ( = src[floor(j/3)] )
//   idx_right = fb_q                     ( = src[floor((j+1)/3)] )
// 不需要第二个读端口，也不需要复制帧缓冲（复制会超出 46 块 BSRAM）。
// The framebuffer is semi-dual-port with **one** read port, yet the blend needs
// two adjacent taps at once.  The address sequence is monotone:
//   raddr = sy*256 + M(i) with M(i) = s(i) + (a3(i)==2 ? 1 : 0)
// With the 1-clock read latency, at clock i+1 fb_q = src[M(i)] and one more
// register gives src[M(i-1)].  A small `hsrc` register remembers the source
// pixel fetched by the most recent column with a3 != 2, which is exactly
// src[s(i)].  Hence idx_left/idx_right above -- no second read port and no
// duplicated framebuffer (a copy would not fit: 2 x 25 > 46 BSRAM blocks).
//
// ## 流水线延迟 / Pipeline latency
// 从 cx/cy 到 rgb 正好 **4** 个时钟：
// exactly **4** clocks from cx/cy to rgb:
//   第 1 拍 / stage 1: BSRAM 读寄存器（ppu_framebuffer 内部）/ BSRAM read reg
//   第 2 拍 / stage 2: 两次调色板查表 + 打拍 / two palette lookups, registered
//   第 3 拍 / stage 3: 常数权重混合 / constant-weight blend
//   第 4 拍 / stage 4: 扫描线衰减 + 边框选择 + 输出寄存器
//                     scanline attenuation + border select + output register
// `de`/`hsync`/`vsync` 以及观测端口都被延迟同样的 4 拍，因此 TMDS 编码器看到的
// (rgb, de, c0, c1) 元组始终一致。
// `de`/`hsync`/`vsync` and the observation ports are delayed by the same 4
// clocks, so the TMDS encoders always see a consistent (rgb, de, c0, c1) tuple.
//
// 观测端口（仅用于仿真；顶层不连接，综合时会被清掉）：
// Observation ports (simulation only; left unconnected by the top level, so
// synthesis sweeps them):
//   raddr_o / sx_o / a3_o / wgt_o —— 与 rgb 同拍的实际取址、源列、stage-A 相位
//                                   与混合权重 / actual fetch address, source
//                                   column, stage-A phase and blend weight,
//                                   aligned with rgb.
// -----------------------------------------------------------------------------
`default_nettype none

module ppu_video_pipeline_720p #(
    // CEA-861 光栅（默认 = VIC 4，1280x720 @ 60 Hz）
    // CEA-861 raster (defaults = VIC 4, 1280x720 @ 60 Hz)
    parameter [11:0] H_ACTIVE = 12'd1280,
    parameter [11:0] H_FP     = 12'd110,
    parameter [11:0] H_SYNC   = 12'd40,
    parameter [11:0] H_BP     = 12'd220,
    parameter [11:0] V_ACTIVE = 12'd720,
    parameter [11:0] V_FP     = 12'd5,
    parameter [11:0] V_SYNC   = 12'd5,
    parameter [11:0] V_BP     = 12'd20,

    // 源几何 / source geometry（SRC_W 固定为 256，行跨度因此是左移 8 位）
    // source geometry (SRC_W is fixed at 256, so the row stride is a shift by 8)
    parameter integer SRC_W   = 256,
    parameter integer SRC_H   = 240,
    parameter integer V_SCALE = 3,      // 240 * 3 = 720

    // 每种模式的水平输出宽度 / horizontal output width per mode
    parameter [11:0] H_OUT_1X = 12'd1024,  // 1:1 -> 正好 4 倍 (256*4) / exactly 4x
    parameter [11:0] H_OUT_43 = 12'd960,   // 4:3 -> 720 行的 4:3 = 960 宽 / 4:3 at 720 lines

    // ------------------------------------------------------------------
    // 锐利双线性参数（全部以 1/256 为单位的定点数）/ sharp-bilinear parameters
    // ------------------------------------------------------------------
    // Fr = frac(4*r/5)，r = 输出列号 mod 5（见头注释）。
    // Fr = frac(4*r/5) for r = output column index mod 5 (see the header).
    parameter integer F0 = 0,           // r=0: frac(0/5)   = 0.0
    parameter integer F1 = 205,         // r=1: frac(4/5)   = 0.8
    parameter integer F2 = 154,         // r=2: frac(8/5)   = 0.6
    parameter integer F3 = 102,         // r=3: frac(12/5)  = 0.4
    parameter integer F4 = 51,          // r=4: frac(16/5)  = 0.2
    // 阈值：f < T_LO 取左，f > T_HI 取右，其余线性混合。
    // Thresholds: f < T_LO -> left, f > T_HI -> right, otherwise linear blend.
    parameter integer T_LO = 51,        // 0.2 in 1/256 units
    parameter integer T_HI = 205,       // 0.8 in 1/256 units
    // 显式权重覆盖：-1 = 按 (Fr, T_LO, T_HI) 推导（默认），>=0 = 强制该权重
    // （256 = 完全取右）。推导出来的权重才是实际参与运算的常系数。
    // Explicit weight override: -1 = derive from (Fr, T_LO, T_HI) (default),
    // >= 0 = force that weight (256 = fully right).  The derived weight is the
    // constant coefficient that actually gets built.
    parameter integer WGT0 = -1,
    parameter integer WGT1 = -1,
    parameter integer WGT2 = -1,
    parameter integer WGT3 = -1,
    parameter integer WGT4 = -1,

    // 扫描线亮度，1/256 单位（256 = 100%）/ scanline brightness, 1/256 units
    // 3 个相位：亮 / 半 / 暗（每 3 个输出行对应 1 个源行）
    // 3 phases: bright / half / dark (3 output lines per source line)
    parameter integer LVL0 = 256,
    parameter integer LVL1 = 128,
    parameter integer LVL2 = 0,

    parameter [23:0] BORDER_RGB = 24'h303030
) (
    input  wire        clk,          // 视频像素时钟 / video pixel clock
    input  wire        rst,          // 视频域复位，高有效，同步 / video reset, active high, sync

    // ---- 帧缓冲写端口（PPU 像素时钟域）/ framebuffer write port ----
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        wr_en,        // = pixel_valid
    input  wire [5:0]  wr_data,      // = pixel_index
    input  wire        wr_vsync,     // PPU 侧 vsync，用于复位写指针 / resets the write pointer

    // ---- 模式 / mode ----
    input  wire        h_mode_43,    // 0 = 1:1 (4x, 1024), 1 = 4:3 (960)

    // ---- 视频输出 / video outputs ----
    output wire [23:0] rgb,
    output wire        de,
    output wire        hsync,
    output wire        vsync,

    // ---- 观测 / observation（与 rgb 同拍 / aligned with rgb）----
    output wire [11:0] cx_o,
    output wire [11:0] cy_o,
    output wire [15:0] raddr_o,
    output wire [7:0]  sx_o,
    output wire [1:0]  a3_o,
    output wire [8:0]  wgt_o
);

    // ------------------------------------------------------------------
    // 推导常数 / derived constants
    // ------------------------------------------------------------------
    localparam [11:0] H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 1650
    localparam [11:0] V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;   //  750
    localparam [11:0] PIC_H   = SRC_H * V_SCALE;                   //  720
    localparam [11:0] V_START = (V_ACTIVE - SRC_H*V_SCALE) / 2;    //    0
    localparam [11:0] H_START_1X = (H_ACTIVE - H_OUT_1X) / 2;      //  128
    localparam [11:0] H_START_43 = (H_ACTIVE - H_OUT_43) / 2;      //  160

    // 由 (Fr, T_LO, T_HI) 推导出的实际混合权重，全部在展开阶段成为常数。
    // The actual blend weights derived from (Fr, T_LO, T_HI); all constants at
    // elaboration time.
    localparam integer WC0 = (WGT0 >= 0) ? WGT0 :
                             ((F0 < T_LO) ? 0 : ((F0 > T_HI) ? 256 : F0));
    localparam integer WC1 = (WGT1 >= 0) ? WGT1 :
                             ((F1 < T_LO) ? 0 : ((F1 > T_HI) ? 256 : F1));
    localparam integer WC2 = (WGT2 >= 0) ? WGT2 :
                             ((F2 < T_LO) ? 0 : ((F2 > T_HI) ? 256 : F2));
    localparam integer WC3 = (WGT3 >= 0) ? WGT3 :
                             ((F3 < T_LO) ? 0 : ((F3 > T_HI) ? 256 : F3));
    localparam integer WC4 = (WGT4 >= 0) ? WGT4 :
                             ((F4 < T_LO) ? 0 : ((F4 > T_HI) ? 256 : F4));

    // ------------------------------------------------------------------
    // CEA-861 光栅计数器 / CEA-861 raster counters
    // ------------------------------------------------------------------
    wire [11:0] cx, cy;
    wire        active;
    wire        hsync_raw, vsync_raw;

    hdmi_timing #(
        .H_ACTIVE (H_ACTIVE), .H_FP (H_FP), .H_SYNC (H_SYNC), .H_BP (H_BP),
        .V_ACTIVE (V_ACTIVE), .V_FP (V_FP), .V_SYNC (V_SYNC), .V_BP (V_BP)
    ) u_timing (
        .clk_pixel (clk),
        .reset     (rst),
        .cx        (cx),
        .cy        (cy),
        .hsync     (hsync_raw),
        .vsync     (vsync_raw),
        .active    (active)
    );

    // ------------------------------------------------------------------
    // 水平几何（计数器，无除法器）/ horizontal geometry (counters, no divider)
    // ------------------------------------------------------------------
    wire [11:0] h_out   = h_mode_43 ? H_OUT_43 : H_OUT_1X;
    wire [11:0] h_start = h_mode_43 ? H_START_43 : H_START_1X;
    wire [11:0] h_end   = h_start + h_out;

    wire in_pic_x = (cx >= h_start) && (cx < h_end);
    wire last_x   = (cx == (h_end - 12'd1));

    // acc/sx 在画面之前的那一个输出列上（重新）启动。
    // (Re)started on the output column just before the picture.
    wire h_restart = (cx == (h_start - 12'd1)) || (cx == (H_TOTAL - 12'd1));

    reg  [7:0] sx;      // 当前输出列对应的源列 / source column of the current output column
    reg  [2:0] r5;      // 输出列号 mod 5（仅 4:3 用）/ output index mod 5 (4:3 only)
    reg  [1:0] a3;      // stage-A 相位 / stage-A phase (0..2, or 0..3 in 1:1 mode)

    wire [1:0] amax  = h_mode_43 ? 2'd2 : 2'd3;
    // stage A 在**本列结束时**是否前进：4:3 下 j = floor(4i/5) 在 i mod 5 != 0
    // 的那些列上 +1；1:1 下每列都 +1。
    // Does stage A advance at the end of this column?  In 4:3, j = floor(4i/5)
    // increments on every column with i mod 5 != 0; in 1:1 it increments every
    // column.
    wire astep = h_mode_43 ? (r5 != 3'd0) : 1'b1;

    always @(posedge clk) begin
        if (rst) begin
            sx <= 8'd0;
            r5 <= 3'd0;
            a3 <= 2'd0;
        end else if (h_restart) begin
            sx <= 8'd0;
            r5 <= 3'd0;
            a3 <= 2'd0;
        end else if (in_pic_x && !last_x) begin
            if (h_mode_43)
                r5 <= (r5 == 3'd4) ? 3'd0 : (r5 + 3'd1);
            if (astep) begin
                if (a3 == amax) begin
                    a3 <= 2'd0;
                    sx <= sx + 8'd1;
                end else begin
                    a3 <= a3 + 2'd1;
                end
            end
        end
    end

    // 帧缓冲取址：M(i) = s(i) + (a3==2 ? 1 : 0)，并在最后一个源列处钳位。
    // Framebuffer address: M(i) = s(i) + (a3==2 ? 1 : 0), clamped at the last
    // source column (stage A has exactly 768 samples, so "j+1" does not exist
    // for the very last output column -> the blend degenerates to "same pixel",
    // which is the correct edge behaviour).
    wire [7:0] maddr = (h_mode_43 && (a3 == 2'd2) && (sx != 8'd255))
                       ? (sx + 8'd1) : sx;

    // ------------------------------------------------------------------
    // 垂直几何：V_SCALE 行重复 + 扫描线相位（计数器，无除法器）
    // Vertical geometry: V_SCALE line repeat + scanline phase (counters, no
    // divider)
    // ------------------------------------------------------------------
    reg  [8:0] sy;      // 源行 0..239 / source line
    reg  [1:0] vph;     // 扫描线相位 0..V_SCALE-1 / scanline phase

    wire [11:0] cy_next  = (cy == (V_TOTAL - 12'd1)) ? 12'd0 : (cy + 12'd1);
    // 下一行就是画面第一行 / the next line is the first picture line
    wire v_restart = (cy_next == V_START);
    wire v_inpic   = (cy >= V_START) && (cy < (V_START + PIC_H));

    always @(posedge clk) begin
        if (rst) begin
            sy  <= 9'd0;
            vph <= 2'd0;
        end else if (cx == (H_TOTAL - 12'd1)) begin
            if (v_restart) begin
                sy  <= 9'd0;
                vph <= 2'd0;
            end else if (v_inpic) begin
                if (vph == (V_SCALE - 1)) begin
                    vph <= 2'd0;
                    sy  <= sy + 9'd1;
                end else begin
                    vph <= vph + 2'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 帧缓冲 + 调色板 / Framebuffer + palette
    // ------------------------------------------------------------------
    wire in_pic = in_pic_x & v_inpic;

    // SRC_W 固定为 256（2 的幂），所以行跨度就是左移 8 位，不生成乘法器。
    // SRC_W is fixed at 256 (a power of two), so the row stride is a shift by
    // 8 and no multiplier is inferred.
    localparam integer SRC_STRIDE_SHIFT = 8;
    wire [15:0] raddr = in_pic
        ? (({7'd0, sy} << SRC_STRIDE_SHIFT) + {8'd0, maddr})
        : 16'd0;

    wire [5:0]  fb_q;

    reg  [15:0] wp;          // 线性写指针 / linear write pointer
    reg         vs_q;

    wire vrise = wr_vsync & ~vs_q;
    wire wren  = wr_en & ~vrise;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wp   <= 16'd0;
            vs_q <= 1'b0;
        end else begin
            vs_q <= wr_vsync;
            if (vrise) begin
                wp <= 16'd0;
            end else if (wr_en) begin
                wp <= (wp == (SRC_W*SRC_H-1)) ? 16'd0 : (wp + 16'd1);
            end
        end
    end

    ppu_framebuffer #(
        .DW    (6),
        .DEPTH (SRC_W*SRC_H)
    ) u_fb (
        .clk_wr (wr_clk),
        .we     (wren),
        .waddr  (wp),
        .wdata  (wr_data),
        .clk_rd (clk),
        .raddr  (raddr),
        .rdata  (fb_q)
    );

    // ------------------------------------------------------------------
    // 流水线第 1 拍：fb_q = src[M(i)]，几何量延后 1 拍
    // Pipeline stage 1: fb_q = src[M(i)]; geometry delayed by one clock
    // ------------------------------------------------------------------
    reg  [1:0] a3_d1;
    reg  [2:0] r5_d1;
    reg        pic_d1;
    reg  [1:0] vph_d1;
    reg  [7:0] sx_d1;
    reg  [11:0] cx_d1, cy_d1;
    reg  [15:0] raddr_d1;

    // 左 tap 寄存器：在 a3 != 2 的列上 fb_q 本身就是 src[s(i)]，记住它，
    // 供后面 a3 == 2（可能连续两列）的列使用。
    // Left-tap register: on columns with a3 != 2 the value fb_q *is* src[s(i)];
    // remember it for the later column(s) with a3 == 2 (there can be two in a
    // row, e.g. i = 10 and 11).
    reg  [5:0] hsrc;

    always @(posedge clk) begin
        if (rst) begin
            a3_d1    <= 2'd0;
            r5_d1    <= 3'd0;
            pic_d1   <= 1'b0;
            vph_d1   <= 2'd0;
            sx_d1    <= 8'd0;
            cx_d1    <= 12'd0;
            cy_d1    <= 12'd0;
            raddr_d1 <= 16'd0;
            hsrc     <= 6'd0;
        end else begin
            a3_d1    <= a3;
            r5_d1    <= r5;
            pic_d1   <= in_pic;
            vph_d1   <= vph;
            sx_d1    <= sx;
            cx_d1    <= cx;
            cy_d1    <= cy;
            raddr_d1 <= raddr;
            if (h_mode_43 && (a3_d1 != 2'd2))
                hsrc <= fb_q;
        end
    end

    wire       blnd  = h_mode_43 & (a3_d1 == 2'd2);
    wire [5:0] idx_l = blnd ? hsrc : fb_q;
    wire [5:0] idx_r = fb_q;

    wire [23:0] pal_l, pal_r;

    nes_palette u_pal_l (.idx (idx_l), .rgb (pal_l));
    nes_palette u_pal_r (.idx (idx_r), .rgb (pal_r));

    // ------------------------------------------------------------------
    // 流水线第 2 拍：把两次调色板查表打拍（切断 ROM -> 混合 -> 衰减的长路径）
    // Pipeline stage 2: register both palette lookups (this cuts the long
    // ROM -> blend -> attenuate path)
    // ------------------------------------------------------------------
    reg  [23:0] pal_l_d;
    reg  [23:0] pal_r_d;
    reg  [2:0]  r5_d2;
    reg  [1:0]  vph_d2;
    reg         pic_d2;
    reg  [7:0]  sx_d2;
    reg  [1:0]  a3_d2;
    reg  [11:0] cx_d2, cy_d2;
    reg  [15:0] raddr_d2;

    always @(posedge clk) begin
        if (rst) begin
            pal_l_d  <= 24'd0;
            pal_r_d  <= 24'd0;
            r5_d2    <= 3'd0;
            vph_d2   <= 2'd0;
            pic_d2   <= 1'b0;
            sx_d2    <= 8'd0;
            a3_d2    <= 2'd0;
            cx_d2    <= 12'd0;
            cy_d2    <= 12'd0;
            raddr_d2 <= 16'd0;
        end else begin
            pal_l_d  <= pal_l;
            pal_r_d  <= pal_r;
            r5_d2    <= r5_d1;
            vph_d2   <= vph_d1;
            pic_d2   <= pic_d1;
            sx_d2    <= sx_d1;
            a3_d2    <= a3_d1;
            cx_d2    <= cx_d1;
            cy_d2    <= cy_d1;
            raddr_d2 <= raddr_d1;
        end
    end

    // ------------------------------------------------------------------
    // 流水线第 3 拍：常数权重混合（不带衰减，单独一拍）
    // Pipeline stage 3: constant-weight blend (attenuation moved to stage 4)
    //
    // 混合与衰减如果在同一拍里做，实测关键路径 slack 只剩 1.970 ns
    // （Fmax 86.97 MHz）—— 够用但太薄。拆成两拍后关键路径变成
    // pal_*_d -> 混合 -> 寄存器，另一拍是寄存器 -> 常系数衰减 -> 输出，
    // 余量明显变大。见 REPORT 的时序表。
    // Doing the blend and the attenuation in one stage left only 1.970 ns of
    // setup slack (Fmax 86.97 MHz) -- passing but thin.  Splitting them makes
    // the critical path "pal_*_d -> blend -> register" and the second one
    // "register -> constant attenuation -> output", with much more margin.
    // See the timing table in the REPORT.
    // ------------------------------------------------------------------
    // 线性混合：w 为右侧抽头的权重（0..256），w 是常数，因此下面的乘法在展开
    // 阶段折叠成移位/加法 —— 不消耗硬件乘法器。
    // 中间积用显式 16 位：255*256 = 65280 放得下，因此 [15:8] 就是结果，
    // 不会触发 EX3791 的位宽截断告警。
    // Linear blend: w is the weight of the right tap (0..256).  w is a
    // constant, so the multiplies below fold to shifts/adds at elaboration
    // time -- no hardware multiplier.  The partial product is given an explicit
    // 16-bit type: 255*256 = 65280 fits, so [15:8] is the result and no EX3791
    // width-truncation warning is emitted.
    function [7:0] mix8;
        input [7:0] a;      // left
        input [7:0] b;      // right
        input integer w;    // weight of b, 0..256
        reg [16:0] p;       // 17 位：a*255 + b*256 最大 65280+... 仍由 [15:8] 取结果
        begin
            p    = a * (256 - w) + b * w;
            mix8 = p[15:8];
        end
    endfunction

    function [23:0] bl_col;
        input [23:0] l;
        input [23:0] r;
        input integer w;
        begin
            bl_col = { mix8(l[23:16], r[23:16], w),
                       mix8(l[15:8],  r[15:8],  w),
                       mix8(l[7:0],   r[7:0],   w) };
        end
    endfunction

    // 混合之后的 RGB，按输出列相位选择常数权重。
    // Blended RGB; the constant weight is selected by the output-column phase.
    reg [23:0] bl_rgb;
    always @(*) begin
        case (r5_d2)
            3'd0:    bl_rgb = bl_col(pal_l_d, pal_r_d, WC0);
            3'd1:    bl_rgb = bl_col(pal_l_d, pal_r_d, WC1);
            3'd2:    bl_rgb = bl_col(pal_l_d, pal_r_d, WC2);
            3'd3:    bl_rgb = bl_col(pal_l_d, pal_r_d, WC3);
            default: bl_rgb = bl_col(pal_l_d, pal_r_d, WC4);
        endcase
    end

    reg  [23:0] bl_rgb_d;
    reg         pic_d3;
    reg  [1:0]  vph_d3;
    reg  [11:0] cx_d3, cy_d3;
    reg  [15:0] raddr_d3;
    reg  [7:0]  sx_d3;
    reg  [1:0]  a3_d3;
    reg  [2:0]  r5_d3;

    always @(posedge clk) begin
        if (rst) begin
            bl_rgb_d <= 24'd0;
            pic_d3   <= 1'b0;
            vph_d3   <= 2'd0;
            cx_d3    <= 12'd0;
            cy_d3    <= 12'd0;
            raddr_d3 <= 16'd0;
            sx_d3    <= 8'd0;
            a3_d3    <= 2'd0;
            r5_d3    <= 3'd0;
        end else begin
            bl_rgb_d <= bl_rgb;
            pic_d3   <= pic_d2;
            vph_d3   <= vph_d2;
            cx_d3    <= cx_d2;
            cy_d3    <= cy_d2;
            raddr_d3 <= raddr_d2;
            sx_d3    <= sx_d2;
            a3_d3    <= a3_d2;
            r5_d3    <= r5_d2;
        end
    end

    // ------------------------------------------------------------------
    // 流水线第 4 拍：扫描线衰减 + 边框选择 + 输出寄存器
    // Pipeline stage 4: scanline attenuation + border select + output register
    // ------------------------------------------------------------------
    // 常系数衰减（与 1080p30 模块相同的写法）：每个 LVLn 都是参数，乘法在
    // 展开阶段折叠成移位/加法。默认 256/128/0 全是 2 的幂，于是只剩移位。
    // Constant-coefficient attenuation (same idiom as the 1080p30 module): each
    // LVLn is a parameter, so the multiplies fold to shifts/adds.  The defaults
    // 256/128/0 are all powers of two, so only shifts remain.
    function [7:0] scale8;
        input [7:0] v;
        input integer lvl;      // 0..256
        reg [16:0] p;           // 17 位，避免 EX3791 位宽告警
        begin
            p      = v * lvl;
            scale8 = p[15:8];
        end
    endfunction

    wire [7:0] r0 = scale8(bl_rgb_d[23:16], LVL0);
    wire [7:0] g0 = scale8(bl_rgb_d[15:8],  LVL0);
    wire [7:0] b0 = scale8(bl_rgb_d[7:0],   LVL0);
    wire [7:0] r1 = scale8(bl_rgb_d[23:16], LVL1);
    wire [7:0] g1 = scale8(bl_rgb_d[15:8],  LVL1);
    wire [7:0] b1 = scale8(bl_rgb_d[7:0],   LVL1);
    wire [7:0] r2 = scale8(bl_rgb_d[23:16], LVL2);
    wire [7:0] g2 = scale8(bl_rgb_d[15:8],  LVL2);
    wire [7:0] b2 = scale8(bl_rgb_d[7:0],   LVL2);

    reg  [23:0] rgb_q;
    reg  [11:0] cx_d4, cy_d4;
    reg  [15:0] raddr_d4;
    reg  [7:0]  sx_d4;
    reg  [1:0]  a3_d4;
    reg  [2:0]  r5_d4;

    always @(posedge clk) begin
        if (rst) begin
            rgb_q    <= BORDER_RGB;
            cx_d4    <= 12'd0;
            cy_d4    <= 12'd0;
            raddr_d4 <= 16'd0;
            sx_d4    <= 8'd0;
            a3_d4    <= 2'd0;
            r5_d4    <= 3'd0;
        end else begin
            if (!pic_d3) begin
                rgb_q <= BORDER_RGB;
            end else begin
                case (vph_d3)
                    2'd0:    rgb_q <= {r0, g0, b0};
                    2'd1:    rgb_q <= {r1, g1, b1};
                    default: rgb_q <= {r2, g2, b2};
                endcase
            end
            cx_d4    <= cx_d3;
            cy_d4    <= cy_d3;
            raddr_d4 <= raddr_d3;
            sx_d4    <= sx_d3;
            a3_d4    <= a3_d3;
            r5_d4    <= r5_d3;
        end
    end

    assign rgb     = rgb_q;
    assign cx_o    = cx_d4;
    assign cy_o    = cy_d4;
    assign raddr_o = raddr_d4;
    assign sx_o    = sx_d4;
    assign a3_o    = a3_d4;

    // 观测用权重：与 bl_rgb 用的是同一组常系数 / observation weight: the same
    // constants bl_rgb uses
    reg [8:0] wgt_q;
    always @(*) begin
        case (r5_d4)
            3'd0:    wgt_q = WC0;
            3'd1:    wgt_q = WC1;
            3'd2:    wgt_q = WC2;
            3'd3:    wgt_q = WC3;
            default: wgt_q = WC4;
        endcase
    end
    assign wgt_o = wgt_q;

    // ------------------------------------------------------------------
    // 让 de/hsync/vsync 与 4 拍的 rgb 延迟对齐
    // Align de/hsync/vsync with the 4-clock rgb latency
    // ------------------------------------------------------------------
    reg [3:0] de_d, hs_d, vs_d;

    always @(posedge clk) begin
        if (rst) begin
            de_d <= 4'b0000;
            hs_d <= 4'b0000;
            vs_d <= 4'b0000;
        end else begin
            de_d <= {de_d[2:0], active};
            hs_d <= {hs_d[2:0], hsync_raw};
            vs_d <= {vs_d[2:0], vsync_raw};
        end
    end

    assign de    = de_d[3];
    assign hsync = hs_d[3];
    assign vsync = vs_d[3];

endmodule

`default_nettype wire
