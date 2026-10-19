// AI-assisted; see NOTICE.md
// TMDS 8b/10b 编码器，依据 DVI 1.0 / HDMI 1.4a 第 5.4 节（Figure 5-7）。
// TMDS 8b/10b encoder, DVI 1.0 / HDMI 1.4a section 5.4 (Figure 5-7).
// 按规范自行编写；只实现视频期与控制期（DVI 风格，无音频 / 数据岛）。
// 每个控制期都会复位运行不一致度，这一点遵循规范（"acc" 在非视频数据期被清零）。
// Written from the specification; video + control periods only (DVI-style, no
// audio / data islands).  Reset of the running disparity on every control period
// follows the spec ("acc" is cleared when not in the video data period).
//
// -----------------------------------------------------------------------------
// 流水化变体（仅用于 ppu-hdmi；hdmi-core/rtl/tmds_encoder.v 是另一个
// 非流水化的文件，*未*被改动）。
// PIPELINED VARIANT (ppu-hdmi only; hdmi-core/rtl/tmds_encoder.v is a
// separate, unpipelined file and is NOT touched).
//
// 原因：本模块从输入到 `acc` 的路径有 17 级逻辑（popcount -> 模式选择 ->
// 8 深 qm 链 -> popcount -> 不一致度加法），是集成版 74.25 MHz 下唯一失败的
// 路径（Fmax 74.021 MHz，TNS -0.042 ns，1 个端点）。
// Why: this module's input-to-`acc` path is 17 logic levels (popcount -> mode
// select -> 8-deep qm chain -> popcount -> disparity add) and was the single
// failing path of the integrated build at 74.25 MHz (Fmax 74.021 MHz, TNS
// -0.042 ns, 1 endpoint).
//
// 改动内容：第 1 级（`n1d`、`xnor_mode`）现在被寄存，同时寄存 `d`、`de`、
// `c0`、`c1`。第 2 级仍从这些寄存器组合地计算 `qm`、两个 popcount、`qout`
// 与 `acc_add`。这样把 17 级路径拆成约 3-4 级 + 约 8 级。
// What changed: stage 1 (`n1d`, `xnor_mode`) is now REGISTERED, together with
// `d`, `de`, `c0`, `c1`.  Stage 2 keeps computing `qm`, the popcounts, `qout`
// and `acc_add` combinationally from those registers.  That splits the 17-level
// path into ~3-4 levels + ~8 levels.
//
// 这是纯粹的流水线改动：输出的 10 位码流与未流水化编码器逐位相同，只是
// 延迟了正好一个 clk_pixel。由于 de/c0/c1 也被同样延迟一个时钟，整个 TMDS
// 码流（数据 + 控制符号 + 运行不一致度）一起平移，因此链路不受影响 ——
// 接收端是从 TMDS 时钟通道恢复像素时钟的。
// This is a pure pipeline change: the emitted 10-bit stream is bit-identical to
// the unpipelined encoder's, delayed by exactly one clk_pixel.  Because de/c0/c1
// are delayed by the same one clock, the whole TMDS stream (data + control
// symbols + running disparity) shifts together, so the link is unaffected --
// the receiver recovers the pixel clock from the TMDS clock lane.
//
//   original:  acc(k+1) = acc(k) + add(d(k), acc(k)),  q(k+1) = qout(d(k), acc(k))
//   pipelined: d_r(k+1) = d(k);  acc(k+2) = acc(k+1) + add(d_r(k+1), acc(k+1))
//              => 同一条轨迹，晚一个时钟边沿。/ => the same trajectory, one edge later.
//
// 已由 tb/tb_tmds_pipe_equiv.v 对照 tb/tmds_encoder_ref.v（原始涟漪写法），
// 在 200,000 个周期上以 1 个时钟的比较偏移验证通过。
// Checked by tb/tb_tmds_pipe_equiv.v against tb/tmds_encoder_ref.v (the
// original ripple form) over 200,000 cycles with a 1-clock comparison offset.
// -----------------------------------------------------------------------------
module tmds_encoder (
    input  wire       clk,
    input  wire [7:0] d,      // 像素分量 / pixel component
    input  wire       c0,     // 控制位 0（通道 0 上为 HSYNC，其余为 0）/ control bit 0 (HSYNC on channel 0, else 0)
    input  wire       c1,     // 控制位 1（通道 0 上为 VSYNC，其余为 0）/ control bit 1 (VSYNC on channel 0, else 0)
    input  wire       de,     // 数据有效：1 = 有效视频期 / data enable: 1 = active video
    output reg  [9:0] q
);

    // ---- 第 1 级寄存器 / stage 1 registers ----
    reg        xnor_r;
    reg  [3:0] n1d_r;
    reg  [7:0] d_r;
    reg        de_r, c0_r, c1_r;

    // ---- 第 2 级组合逻辑 / stage 2 combinational ----
    reg  [8:0] qm;
    reg  [3:0] n1qm;
    reg  [4:0] n0qm;
    reg  [9:0] qout;
    reg  [5:0] acc_add;
    reg signed [5:0] acc;

    integer i;

    // ------------------------------------------------------------------
    // 第 1 级：8 -> 9 位，尽量减少跳变（寄存）
    // Stage 1: 8 -> 9 bits, minimise transitions (registered)
    // ------------------------------------------------------------------
    reg [3:0] n1d_c;
    reg       xnor_c;

    always @(*) begin
        n1d_c = 4'd0;
        for (i = 0; i < 8; i = i + 1)
            n1d_c = n1d_c + {3'd0, d[i]};
        xnor_c = (n1d_c > 4'd4) || ((n1d_c == 4'd4) && (d[0] == 1'b0));
    end

    always @(posedge clk) begin
        n1d_r <= n1d_c;
        xnor_r <= xnor_c;
        d_r   <= d;
        de_r  <= de;
        c0_r  <= c0;
        c1_r  <= c1;
    end

    // ------------------------------------------------------------------
    // 第 2 级：9 -> 10 位，直流平衡
    // Stage 2: 9 -> 10 bits, DC balance
    // ------------------------------------------------------------------
    always @(*) begin
        qm[0] = d_r[0];
        for (i = 1; i < 8; i = i + 1)
            qm[i] = xnor_r ? (qm[i-1] ~^ d_r[i]) : (qm[i-1] ^ d_r[i]);

        qm[8] = ~xnor_r;          // 1 = XOR 模式，0 = XNOR 模式 / 1 = XOR mode, 0 = XNOR mode

        n1qm = 4'd0;
        for (i = 0; i < 8; i = i + 1)
            n1qm = n1qm + {3'd0, qm[i]};
        n0qm = 5'd8 - {1'b0, n1qm};

        if ((acc == 6'sd0) || (n1qm == n0qm)) begin
            // 尚无运行不一致度，或完全平衡：按 qm[8] 选择
            // no running disparity yet, or perfectly balanced: choose by qm[8]
            if (qm[8]) begin
                qout    = {~qm[8], qm[8],  qm[7:0]};
                acc_add = {1'b0, n1qm} - {1'b0, n0qm};
            end else begin
                qout    = {~qm[8], qm[8], ~qm[7:0]};
                acc_add = {1'b0, n0qm} - {1'b0, n1qm};
            end
        end else if (((acc > 6'sd0) && (n1qm > n0qm)) ||
                     ((acc < 6'sd0) && (n1qm < n0qm))) begin
            qout    = {1'b1, qm[8], ~qm[7:0]};
            acc_add = ({1'b0, n0qm} - {1'b0, n1qm}) + (qm[8] ? 6'sd2 : 6'sd0);
        end else begin
            qout    = {1'b0, qm[8],  qm[7:0]};
            acc_add = ({1'b0, n1qm} - {1'b0, n0qm}) - (qm[8] ? 6'sd0 : 6'sd2);
        end
    end

    always @(posedge clk) begin
        if (!de_r) begin
            // 控制期，运行不一致度重新开始 / control period, running disparity restarts
            acc <= 6'sd0;
            case ({c1_r, c0_r})
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                2'b11: q <= 10'b1010101011;
            endcase
        end else begin
            acc <= acc + acc_add;
            q   <= qout;
        end
    end

endmodule
