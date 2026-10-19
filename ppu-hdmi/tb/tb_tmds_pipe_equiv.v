// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// tb_tmds_pipe_equiv.v
//
// 证明*流水化*的 rtl/tmds_encoder.v 与原始非流水化编码器
// （tb/tmds_encoder_ref.v）输出的 10 位码流完全相同，只是晚一个 clk_pixel。
// Proves that the PIPELINED rtl/tmds_encoder.v emits exactly the same 10-bit
// stream as the original, unpipelined encoder (tb/tmds_encoder_ref.v), just one
// clk_pixel later.
//
// 方法：两个编码器每个时钟都拿到相同激励；参考模型的输出延迟一个时钟
// （`q_ref_d`）后与流水化输出比较。由于 de/hsync/vsync 在流水化编码器内部
// 也被延迟了，所以每个周期都匹配就意味着整个 TMDS 码流 —— 数据符号、控制
// 符号以及运行不一致度状态 —— 完全一致，只是平移了。
// Method: both encoders get identical stimulus every clock; the reference's
// output is delayed by one clock (`q_ref_d`) and compared with the pipelined
// output.  Because de/hsync/vsync are delayed inside the pipelined encoder too,
// a match on every cycle means the whole TMDS stream -- data symbols, control
// symbols and the running-disparity state -- is identical, only shifted.
//
// 覆盖范围：de=1 期间反复遍历全部 256 个数据值；de=0 期间遍历全部四种
// {c1,c0} 控制码（这同时会复位运行不一致度）；再加一段伪随机相位。
// 总共 200,000 个周期。
// Coverage: all 256 data values repeatedly during de=1, all four {c1,c0}
// control codes during de=0 (which also resets the running disparity), plus a
// pseudo-random phase.  200,000 cycles total.
// -----------------------------------------------------------------------------
module tb_tmds_pipe_equiv;

    reg        clk = 1'b0;
    reg  [7:0] d   = 8'h00;
    reg        c0  = 1'b0;
    reg        c1  = 1'b0;
    reg        de  = 1'b0;

    wire [9:0] q_pipe, q_ref;

    tmds_encoder u_pipe (
        .clk(clk), .d(d), .c0(c0), .c1(c1), .de(de), .q(q_pipe)
    );

    tmds_encoder_ref u_ref (
        .clk(clk), .d(d), .c0(c0), .c1(c1), .de(de), .q(q_ref)
    );

    // 流水化编码器的码流比原始版本超前一个时钟
    // the pipelined encoder is one clk ahead of the original's stream
    reg [9:0] q_ref_d = 10'h000;
    always @(posedge clk) q_ref_d <= q_ref;

    always #5 clk = ~clk;

    integer n;
    integer checks = 0;
    integer errors = 0;
    reg [7:0] lfsr;

    initial begin
        $display("==================================================================");
        $display(" TMDS encoder equivalence: pipelined vs original (1-clock offset)");
        $display("==================================================================");

        // 清空两个编码器的运行不一致度（de = 0 -> acc <= 0）
        // clear the running disparity in both encoders (de = 0 -> acc <= 0)
        de = 1'b0; c0 = 1'b0; c1 = 1'b0; d = 8'h00;
        repeat (6) @(posedge clk);

        // ---- 第 1 阶段：遍历每个数据值，其间插入控制期 ----
        // ---- phase 1: every data value, control periods interleaved ----
        for (n = 0; n < 100000; n = n + 1) begin
            if ((n % 89) == 0) begin
                de = 1'b0;
                c0 = n[0];
                c1 = n[1];
            end else begin
                de = 1'b1;
                c0 = 1'b0;
                c1 = 1'b0;
                d  = d + 8'd1;          // 扫过全部 256 个值 / sweeps all 256 values
            end
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (q_pipe !== q_ref_d) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("    FAIL  n=%0d de=%b c=%b%b d=%02h  pipe=%03h ref_d=%03h",
                             n, de, c1, c0, d, q_pipe, q_ref_d);
            end
        end

        // ---- 第 2 阶段：伪随机数据 / ---- phase 2: pseudo-random data ----
        lfsr = 8'h5A;
        for (n = 0; n < 100000; n = n + 1) begin
            lfsr = {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
            de = (n % 211) != 0;
            c0 = lfsr[0];
            c1 = lfsr[1];
            d  = lfsr;
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (q_pipe !== q_ref_d) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("    FAIL  n=%0d de=%b c=%b%b d=%02h  pipe=%03h ref_d=%03h",
                             n, de, c1, c0, d, q_pipe, q_ref_d);
            end
        end

        $display("\n  cycles compared : %0d", checks);
        $display("  mismatches      : %0d", errors);
        if (errors == 0)
            $display(" RESULT: PASS  (pipelined stream == original stream, 1 clk later)");
        else
            $display(" RESULT: FAIL");
        $display("==================================================================");
        $finish;
    end

endmodule
