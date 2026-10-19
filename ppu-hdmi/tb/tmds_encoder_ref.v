// AI-assisted; see NOTICE.md
// TMDS 8b/10b 编码器，依据 DVI 1.0 / HDMI 1.4a 第 5.4 节（Figure 5-7）。
// 这是*原始非流水化*的参考实现，仅供 tb_tmds_pipe_equiv.v 做等价性比对；
// 它不是可综合的设计源文件。
// TMDS 8b/10b encoder, DVI 1.0 / HDMI 1.4a section 5.4 (Figure 5-7).
// This is the ORIGINAL, UNPIPELINED reference implementation.  It exists only
// so that tb_tmds_pipe_equiv.v can compare against it; it is not a synthesised
// design source.
// 按规范自行编写；只实现视频期与控制期（DVI 风格，无音频 / 数据岛）。
// 每个控制期都会复位运行不一致度，这一点遵循规范
// （"acc" 在非视频数据期被清零）。
// Written from the specification; video + control periods only (DVI-style, no
// audio / data islands).  Reset of the running disparity on every control period
// follows the spec ("acc" is cleared when not in the video data period).
module tmds_encoder_ref (
    input  wire       clk,
    input  wire [7:0] d,      // 像素分量 / pixel component
    input  wire       c0,     // 控制位 0（通道 0 上为 HSYNC，其余为 0）/ control bit 0 (HSYNC on channel 0, else 0)
    input  wire       c1,     // 控制位 1（通道 0 上为 VSYNC，其余为 0）/ control bit 1 (VSYNC on channel 0, else 0)
    input  wire       de,     // 数据有效：1 = 有效视频期 / data enable: 1 = active video
    output reg  [9:0] q
);

reg        xnor_mode;
reg  [3:0] n1d;
reg  [8:0] qm;
reg  [3:0] n1qm;
reg  [4:0] n0qm;
reg  [9:0] qout;
reg signed [5:0] acc;
reg signed [5:0] acc_add;

integer i;

always @(*) begin
    // ---- 第 1 级：8 -> 9 位，尽量减少跳变 ----
    // ---- Stage 1: 8 -> 9 bits, minimise transitions ----
    n1d = 4'd0;
    for (i = 0; i < 8; i = i + 1)
        n1d = n1d + {3'd0, d[i]};

    xnor_mode = (n1d > 4'd4) || ((n1d == 4'd4) && (d[0] == 1'b0));

    qm[0] = d[0];
    for (i = 1; i < 8; i = i + 1)
        qm[i] = xnor_mode ? (qm[i-1] ~^ d[i]) : (qm[i-1] ^ d[i]);

    qm[8] = ~xnor_mode;          // 1 = XOR 模式，0 = XNOR 模式 / 1 = XOR mode, 0 = XNOR mode

    // ---- 第 2 级：9 -> 10 位，直流平衡 ----
    // ---- Stage 2: 9 -> 10 bits, DC balance ----
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
    if (!de) begin
        // 控制期，运行不一致度重新开始 / control period, running disparity restarts
        acc <= 6'sd0;
        case ({c1, c0})
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
