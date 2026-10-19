// AI-assisted; see NOTICE.md
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// tb_ppu_intercept.v
//
// PPU 采集转接板的自检 testbench。
// Self-checking testbench for the PPU capture interposer.
//
// 测试场景：
// Scenarios:
//   1. CPU 对 $2000/$2001 的正常写入原样透传。
//   1. Normal CPU writes to $2000/$2001 pass through unchanged.
//   2. FPGA 注入写入 $2000 时带上 EXT 输出位。
//   2. An FPGA injection writes $2000 with the EXT-output bit set.
//   3. CPU 写清除该位时会被守卫；输出模式仍然保持。
//   3. A CPU write that clears that bit is guarded; output mode survives.
//   4. 注入时序：CPU 与注入不重叠，建立/保持裕量。
//   4. Injection timing: no CPU/injection overlap, setup/hold margins.
//   5. $2006/$2007 调色板影子写、+1/+32 自增、镜像。
//   5. $2006/$2007 palette-shadow writes, +1/+32 increment, mirroring.
//   6. EXT0..EXT3 + ext4 的像素采集与调色板查表。
//   6. EXT0..EXT3 + ext4 pixel capture and palette lookup.
//   7. $2006 写顺序，以及序列中途改变 $2000 自增模式。
//   7. $2006 write ordering and a mid-sequence $2000 increment change.
//
// PPU 被建模为一个寄存器堆，在 phi2 上升沿采样 PPU 侧总线。数据总线是真正的
// 三态线，以便看到驱动器争用。EXT 按干净的数字总线驱动；产生 ext4/blank/sync
// 的模拟比较器*不*建模。
// The PPU is modelled as a register file that samples the PPU-side bus on the
// rising edge of phi2.  The data bus is a real tri-state wire so that driver
// contention is visible.  EXT is driven as a clean digital bus; the analog
// comparator that makes ext4/blank/sync is NOT modelled.
//
// 默认 EXT_OUT_BIT=6（有文档依据的 2C02 EXT 方向位）。若要复现任务书原始
// 变体，用 -P tb_ppu_intercept.EXT_OUT_BIT=2 编译。
// Default EXT_OUT_BIT=6 (documented 2C02 EXT-direction bit).  Build with
// -P tb_ppu_intercept.EXT_OUT_BIT=2 for the original task-statement variant.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_ppu_intercept;

    // ------------------------------------------------------------------
    // 参数与假设 / Parameters and assumptions
    // ------------------------------------------------------------------
    parameter integer EXT_OUT_BIT = 6;

    // 2C02 寄存器总线时序假设，单位纳秒。这些值刻意取得保守，并不是厂商
    // 数据手册上的数字；见 REPORT.md。检查器强制执行的就是这些值。
    // 2C02 register-bus timing assumptions, in nanoseconds.  These are
    // deliberately conservative and are not vendor datasheet numbers; see
    // REPORT.md.  They are the values the checker enforces.
    parameter real T_SU  = 20.0;   // /CS, R/W, A0..A2 setup before phi2 rise
    parameter real T_H   = 10.0;   // /CS, R/W, A0..A2 hold after phi2 rise
    parameter real T_DSU = 50.0;   // D0..D7 setup before phi2 rise
    parameter real T_DH  = 10.0;   // D0..D7 hold after phi2 rise

    localparam real CLK_PERIOD  = 46.56;   // 21.47727 MHz
    localparam real PHI2_PERIOD = 186.24;  // 5.3693175 MHz

    localparam [7:0] EXT_OUT_MASK = (8'h01 << EXT_OUT_BIT);

    // ------------------------------------------------------------------
    // 时钟与 DUT 信号 / Clocks and DUT signals
    // ------------------------------------------------------------------
    reg clk;
    reg rst_n;
    reg phi2;

    reg        cpu_cs_n;
    reg        cpu_rw;
    reg  [2:0] cpu_a;
    reg  [7:0] cpu_d_in;
    wire [7:0] cpu_d_out;
    wire       cpu_d_oe;

    wire       ppu_cs_n;
    wire       ppu_rw;
    wire [2:0] ppu_a;
    wire [7:0] ppu_d_out;
    wire       ppu_d_oe;
    wire [7:0] ppu_bus;

    // EXT / 比较器侧输入 / EXT / comparator-side inputs
    reg  [3:0] ext_i;
    reg        ext4_bg_sprite_i;
    reg        hsync_i;
    reg        vsync_i;
    reg        blank_i;

    // 采集到的像素结果 / Captured pixel result
    wire [5:0] pixel_index;
    wire [4:0] pixel_palette_addr;
    wire       pixel_valid;
    wire [2:0] emphasis;
    wire       grayscale;

    reg        capture_en;
    reg        inject_req;
    wire       inject_ack;
    wire       inject_busy;
    wire       inject_collision;
    wire [7:0] ctrl_shadow;
    wire       ext_out_bit_held;

    integer checks;
    integer errors;

    // ------------------------------------------------------------------
    // 被测模块 / DUT
    // ------------------------------------------------------------------
    ppu_capture_intercept #(
        .EXT_OUT_BIT (EXT_OUT_BIT)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .phi2             (phi2),
        .cpu_cs_n         (cpu_cs_n),
        .cpu_rw           (cpu_rw),
        .cpu_a            (cpu_a),
        .cpu_d_in         (cpu_d_in),
        .cpu_d_out        (cpu_d_out),
        .cpu_d_oe         (cpu_d_oe),
        .ppu_cs_n         (ppu_cs_n),
        .ppu_rw           (ppu_rw),
        .ppu_a            (ppu_a),
        .ppu_d_out        (ppu_d_out),
        .ppu_d_oe         (ppu_d_oe),
        .ppu_d_in         (ppu_bus),
        .ext_i            (ext_i),
        .ext4_bg_sprite_i (ext4_bg_sprite_i),
        .hsync_i          (hsync_i),
        .vsync_i          (vsync_i),
        .blank_i          (blank_i),
        .pixel_index_o    (pixel_index),
        .pixel_palette_addr_o (pixel_palette_addr),
        .pixel_valid_o    (pixel_valid),
        .emphasis_o       (emphasis),
        .grayscale_o      (grayscale),
        .capture_en       (capture_en),
        .inject_req       (inject_req),
        .inject_ack       (inject_ack),
        .inject_busy      (inject_busy),
        .inject_collision (inject_collision),
        .ctrl_shadow      (ctrl_shadow),
        .ext_out_bit_held (ext_out_bit_held)
    );

    // 真正的开漏风格数据总线。DUT 与 PPU 模型只在各自输出使能为高时驱动。
    // Real open-drain-style data bus.  The DUT and the PPU model each drive
    // only when their output enable is high.
    assign ppu_bus = ppu_d_oe ? ppu_d_out : 8'bz;

    // ------------------------------------------------------------------
    // 简化的 2C02 寄存器模型 / Simple 2C02 register model
    // ------------------------------------------------------------------
    reg [7:0] ppu_ctrl;
    reg [7:0] ppu_mask;
    reg [7:0] last_ppu_data;
    reg [2:0] last_ppu_addr;
    integer   ppu_writes;
    reg       ppu_wr_seen;

    integer   model_writes_start;
    wire      model_oe;
    wire [7:0] model_dout;

    // 读数据：固定的非零值，便于检查读通路透传。
    // Read data: a fixed non-zero value so a read-passthrough check is easy.
    assign model_oe   = ~ppu_cs_n & ppu_rw;
    assign model_dout = (ppu_a == 3'b010) ? 8'hA5 : 8'h5A;
    assign ppu_bus    = model_oe ? model_dout : 8'bz;

    always @(posedge phi2 or negedge rst_n) begin
        if (!rst_n) begin
            ppu_ctrl      <= 8'h00;
            ppu_mask      <= 8'h00;
            last_ppu_data <= 8'h00;
            last_ppu_addr <= 3'b000;
            ppu_writes    <= 0;
            ppu_wr_seen   <= 1'b0;
        end else begin
            if (~ppu_cs_n & ~ppu_rw) begin
                if (~ppu_wr_seen) begin
                    ppu_writes    <= ppu_writes + 1;
                    last_ppu_data <= ppu_bus;
                    last_ppu_addr <= ppu_a;
                    $display("  [PPU] t=%0.2f ns  write $200%0d = 0x%02x",
                             $realtime, ppu_a, ppu_bus);
                    if (ppu_a == 3'b000)
                        ppu_ctrl <= ppu_bus;
                    if (ppu_a == 3'b001)
                        ppu_mask <= ppu_bus;
                end
                ppu_wr_seen <= 1'b1;
            end else begin
                ppu_wr_seen <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // 注入时序捕获 / Injection timing capture
    // ------------------------------------------------------------------
    real t_inj_assert;
    real t_inj_sample;
    real t_inj_deassert;
    real inj_setup;
    real inj_hold;
    real inj_data_setup;
    real inj_data_hold;
    reg  inj_sampled;
    reg  [7:0] inj_sample_data;
    reg  [2:0] inj_sample_addr;
    reg  inj_sample_cs;
    reg  inj_sample_rw;

    always @(posedge dut.inj_active or negedge rst_n) begin
        if (!rst_n) begin
            t_inj_assert <= 0.0;
            inj_sampled  <= 1'b0;
        end else begin
            t_inj_assert <= $realtime;
            inj_sampled  <= 1'b0;
        end
    end

    always @(posedge phi2) begin
        if (dut.inj_active) begin
            t_inj_sample    <= $realtime;
            inj_sampled     <= 1'b1;
            inj_sample_data <= ppu_bus;
            inj_sample_addr <= ppu_a;
            inj_sample_cs   <= ppu_cs_n;
            inj_sample_rw   <= ppu_rw;
        end
    end

    always @(negedge dut.inj_active) begin
        if (inj_sampled) begin
            t_inj_deassert = $realtime;
            inj_setup      = t_inj_sample - t_inj_assert;
            inj_hold       = $realtime - t_inj_sample;
            inj_data_setup = t_inj_sample - t_inj_assert;
            inj_data_hold  = $realtime - t_inj_sample;
            $display("  [TIMING] injection: assert t=%0.2f, sample t=%0.2f, release t=%0.2f ns",
                     t_inj_assert, t_inj_sample, $realtime);
            $display("  [TIMING]   setup=%.2f ns  hold=%.2f ns",
                     inj_setup, inj_hold);
        end
    end

    // ------------------------------------------------------------------
    // 碰撞 / 争用监视器 / Collision / contention monitors
    // ------------------------------------------------------------------
    reg cpu_inj_overlap;
    reg bus_contention;

    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.inj_active && ~cpu_cs_n)
                cpu_inj_overlap <= 1'b1;
            if (ppu_d_oe && model_oe)
                bus_contention <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // 时钟生成 / Clock generation
    // ------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    initial begin
        phi2 = 1'b0;
        forever #(PHI2_PERIOD / 2.0) phi2 = ~phi2;
    end

    // ------------------------------------------------------------------
    // 辅助任务 / Helpers
    // ------------------------------------------------------------------
    task check8;
        input [7:0]   got;
        input [7:0]   exp;
        input [8*96-1:0] msg;
        begin
            checks = checks + 1;
            if (got === exp) begin
                $display("    PASS  %0s  (got 0x%02x)", msg, got);
            end else begin
                errors = errors + 1;
                $display("    FAIL  %0s  (got 0x%02x, expected 0x%02x)",
                         msg, got, exp);
            end
        end
    endtask

    task check6;
        input [5:0]   got;
        input [5:0]   exp;
        input [8*96-1:0] msg;
        begin
            checks = checks + 1;
            if (got === exp) begin
                $display("    PASS  %0s  (got 0x%02x)", msg, got);
            end else begin
                errors = errors + 1;
                $display("    FAIL  %0s  (got 0x%02x, expected 0x%02x)",
                         msg, got, exp);
            end
        end
    endtask

    task check_true;
        input         cond;
        input [8*96-1:0] msg;
        begin
            checks = checks + 1;
            if (cond) begin
                $display("    PASS  %0s", msg);
            end else begin
                errors = errors + 1;
                $display("    FAIL  %0s", msg);
            end
        end
    endtask

    task check_ge;
        input real    got;
        input real    requirement;
        input [8*96-1:0] msg;
        begin
            checks = checks + 1;
            if (got >= requirement) begin
                $display("    PASS  %0s: measured %0.2f ns >= %0.2f ns (margin %0.2f ns)",
                         msg, got, requirement, got - requirement);
            end else begin
                errors = errors + 1;
                $display("    FAIL  %0s: measured %0.2f ns < %0.2f ns",
                         msg, got, requirement);
            end
        end
    endtask

    task cpu_write;
        input [2:0] a;
        input [7:0] d;
        begin
            @(negedge clk);
            cpu_a    = a;
            cpu_d_in = d;
            cpu_rw   = 1'b1;
            cpu_cs_n = 1'b1;
            #20;
            cpu_rw   = 1'b0;
            cpu_cs_n = 1'b0;
            #220;                    // write asserted for > one phi2 period
            cpu_cs_n = 1'b1;
            cpu_rw   = 1'b1;
            #30;
            cpu_d_in = 8'h00;
            #150;
        end
    endtask

    // $2006 高字节、$2006 低字节、$2007 数据 / $2006 high, $2006 low, $2007 data
    task pal_write;
        input [13:0] addr;
        input [5:0]  data;
        begin
            cpu_write(3'b110, {2'b00, addr[13:8]});
            cpu_write(3'b110, addr[7:0]);
            cpu_write(3'b111, {2'b00, data});
        end
    endtask

    task do_inject;
        integer i;
        reg     got_ack;
        begin
            @(negedge clk);
            inject_req = 1'b1;
            @(negedge clk);
            inject_req = 1'b0;

            got_ack = 1'b0;
            i = 0;
            while ((i < 500) && !got_ack) begin
                @(posedge clk);
                if (inject_ack)
                    got_ack = 1'b1;
                i = i + 1;
            end
            if (!got_ack) begin
                errors = errors + 1;
                $display("    FAIL  injection timed out (no ack)");
            end
            #250;
        end
    endtask

    // ------------------------------------------------------------------
    // 测试序列 / Test sequence
    // ------------------------------------------------------------------
    integer e0;
    reg [7:0] expected_inj;

    initial begin
        $dumpfile("ppu_intercept.vcd");
        $dumpvars(0, tb_ppu_intercept);

        checks = 0;
        errors = 0;
        cpu_inj_overlap = 1'b0;
        bus_contention  = 1'b0;
        capture_en      = 1'b0;
        inject_req      = 1'b0;
        cpu_cs_n        = 1'b1;
        cpu_rw          = 1'b1;
        cpu_a           = 3'b000;
        cpu_d_in        = 8'h00;
        ext_i           = 4'h0;
        ext4_bg_sprite_i= 1'b0;
        hsync_i         = 1'b0;
        vsync_i         = 1'b0;
        blank_i         = 1'b1;
        rst_n           = 1'b0;

        $display("================================================================");
        $display(" PPU capture interposer simulation");
        $display(" EXT_OUT_BIT=%0d (mask 0x%02x), phi2 period=%0.2f ns, clk=%0.2f ns",
                 EXT_OUT_BIT, EXT_OUT_MASK, PHI2_PERIOD, CLK_PERIOD);
        $display("================================================================");

        #300;
        rst_n = 1'b1;
        #250;

        // --------------------------------------------------------------
        $display("");
        $display("=== SCENARIO 1: normal CPU writes pass through unchanged ===");
        e0 = errors;
        model_writes_start = ppu_writes;

        cpu_write(3'b000, 8'h90);
        check8(ppu_ctrl, 8'h90, "S1 $2000=0x90 reaches PPU unchanged");

        cpu_write(3'b000, 8'h00);
        check8(ppu_ctrl, 8'h00, "S1 $2000=0x00 really clears bit 7/4 (no force)");

        cpu_write(3'b000, 8'h90);
        check8(ppu_ctrl, 8'h90, "S1 $2000=0x90 restored");

        cpu_write(3'b001, 8'h1E);
        check8(ppu_mask, 8'h1E, "S1 $2001=0x1E reaches PPU unchanged");
        check_true(ppu_writes == model_writes_start + 4,
                   "S1 exactly four PPU writes observed");

        // 读通路。/ Read path.
        @(negedge clk);
        cpu_a    = 3'b010;
        cpu_rw   = 1'b1;
        cpu_cs_n = 1'b0;
        #150;
        check8(cpu_d_out, 8'hA5, "S1 PPU read data returns to CPU unchanged");
        check_true(cpu_d_oe == 1'b1, "S1 CPU read output enable asserted");
        #100;
        cpu_cs_n = 1'b1;
        #150;

        if (errors == e0)
            $display("[SCENARIO 1] PASS");
        else
            $display("[SCENARIO 1] FAIL");

        // --------------------------------------------------------------
        $display("");
        $display("=== SCENARIO 2: FPGA injects $2000 with EXT-output bit set ===");
        e0 = errors;
        model_writes_start = ppu_writes;

        @(negedge clk);
        capture_en = 1'b1;
        #200;

        check_true(ext_out_bit_held == 1'b0, "S2 EXT-output bit clear before injection");

        expected_inj = 8'h90 | EXT_OUT_MASK;
        do_inject;

        $display("  [INJ] expected injected byte = 0x%02x, sampled = 0x%02x",
                 expected_inj, inj_sample_data);
        check8(ppu_ctrl, expected_inj, "S2 PPU received injected $2000 value");
        check_true(ppu_ctrl[EXT_OUT_BIT] == 1'b1, "S2 EXT-output bit set in PPU $2000");
        check8(inj_sample_data, expected_inj, "S2 data sampled on PPU bus");
        check_true(inj_sample_addr == 3'b000, "S2 injection address is $2000");
        check_true(inj_sample_cs == 1'b0 && inj_sample_rw == 1'b0,
                   "S2 injection was a PPU write cycle");
        check_true(ppu_writes == model_writes_start + 1,
                   "S2 exactly one injected write observed");
        check_true(inject_collision == 1'b0, "S2 no injection collision");

        if (errors == e0)
            $display("[SCENARIO 2] PASS");
        else
            $display("[SCENARIO 2] FAIL");

        // --------------------------------------------------------------
        $display("");
        $display("=== SCENARIO 3: CPU clear of EXT-output bit cannot leave output mode ===");
        e0 = errors;
        model_writes_start = ppu_writes;

        cpu_write(3'b000, 8'h00);
        check8(ppu_ctrl, EXT_OUT_MASK,
               "S3 CPU $2000=0x00 arrives with EXT-output bit forced");

        cpu_write(3'b000, 8'h90);
        check8(ppu_ctrl, 8'h90 | EXT_OUT_MASK,
               "S3 CPU $2000=0x90 preserves other bits, EXT output stays set");

        cpu_write(3'b000, 8'h7F);
        check8(ppu_ctrl, 8'h7F | EXT_OUT_MASK,
               "S3 CPU $2000=0x7F still cannot clear EXT-output bit");

        check_true(ext_out_bit_held == 1'b1, "S3 shadow reports EXT-output bit held");
        check_true(ppu_writes == model_writes_start + 3,
                   "S3 three CPU writes, no extra injection");
        check_true(ppu_ctrl[EXT_OUT_BIT] == 1'b1, "S3 EXT-output bit survived all writes");

        if (errors == e0)
            $display("[SCENARIO 3] PASS");
        else
            $display("[SCENARIO 3] FAIL");

        // --------------------------------------------------------------
        $display("");
        $display("=== SCENARIO 4: injection timing margin and no collision ===");
        e0 = errors;
        cpu_inj_overlap = 1'b0;
        bus_contention  = 1'b0;

        do_inject;

        check_true(cpu_inj_overlap == 1'b0, "S4 no CPU write during injection");
        check_true(bus_contention == 1'b0, "S4 no PPU data-bus contention");
        check_true(inject_collision == 1'b0, "S4 injector reports no collision");

        check_ge(inj_setup, T_SU, "S4 /CS, R/W, A0..A2 setup");
        check_ge(inj_hold, T_H, "S4 /CS, R/W, A0..A2 hold");
        check_ge(inj_data_setup, T_DSU, "S4 D0..D7 setup");
        check_ge(inj_data_hold, T_DH, "S4 D0..D7 hold");

        $display("  [S4] measured injection window: setup=%0.2f ns, hold=%0.2f ns",
                 inj_setup, inj_hold);
        $display("  [S4] requirements: setup >= %0.2f ns, data setup >= %0.2f ns, hold >= %0.2f ns",
                 T_SU, T_DSU, T_H);

        if (errors == e0)
            $display("[SCENARIO 4] PASS");
        else
            $display("[SCENARIO 4] FAIL");

        // --------------------------------------------------------------
        $display("");
        $display("=== SCENARIO 5: palette shadow writes, increment, mirroring ===");
        e0 = errors;

        // 开启采集，bit 2 = 0（+1 自增）。/ Capture on, bit 2 = 0 (+1 increment).
        cpu_write(3'b000, 8'h00);
        check8(ctrl_shadow, 8'h40, "S5 $2000 shadow has EXT-output bit set, +1 inc");

        cpu_write(3'b110, 8'h3F);       // $2006 high = $3F
        cpu_write(3'b110, 8'h00);       // $2006 low  = $00
        cpu_write(3'b111, 8'h0F);       // $3F00 = $0F
        cpu_write(3'b111, 8'h01);       // $3F01 = $01
        cpu_write(3'b111, 8'h21);       // $3F02 = $21

        check6(dut.u_palette.pal_mem[0], 6'h0F, "S5 palette[0x00] = 0x0F");
        check6(dut.u_palette.pal_mem[1], 6'h01, "S5 palette[0x01] = 0x01");
        check6(dut.u_palette.pal_mem[2], 6'h21, "S5 palette[0x02] = 0x21");
        check_true(dut.u_palette.ppu_addr == 14'h3F03,
                   "S5 +1 auto-increment reached $3F03");

        // 开启采集，bit 2 = 1（+32 自增）。/ Capture on, bit 2 = 1 (+32 increment).
        cpu_write(3'b000, 8'h04);
        check8(ctrl_shadow, 8'h44, "S5 $2000 shadow has bit 2 set (+32 inc)");
        cpu_write(3'b110, 8'h3F);
        cpu_write(3'b110, 8'h00);
        cpu_write(3'b111, 8'h30);       // $3F00 = $30, then +32 -> $3F20
        check6(dut.u_palette.pal_mem[0], 6'h30, "S5 +32 write updated palette[0x00]");
        check_true(dut.u_palette.ppu_addr == 14'h3F20,
                   "S5 +32 auto-increment reached $3F20");

        cpu_write(3'b111, 8'h31);       // $3F20 is outside palette range: ignored
        check6(dut.u_palette.pal_mem[1], 6'h01,
               "S5 out-of-range $2007 did not modify palette[0x01]");
        check_true(dut.u_palette.ppu_addr == 14'h3F40,
                   "S5 out-of-range write still incremented to $3F40");

        // 镜像 $3F10 -> $3F00。/ Mirror $3F10 -> $3F00.
        cpu_write(3'b000, 8'h00);
        cpu_write(3'b110, 8'h3F);
        cpu_write(3'b110, 8'h10);
        cpu_write(3'b111, 8'h2A);
        check6(dut.u_palette.pal_mem[0], 6'h2A,
               "S5 $3F10 write mirrors to palette[0x00]");
        check6(dut.u_palette.pal_mem[5'h10], 6'h00,
               "S5 palette[0x10] itself is not separately populated");

        // $2001 强调色 + 灰度捕获。/ $2001 emphasis + grayscale capture.
        cpu_write(3'b001, 8'hE1);
        check8({5'b0, emphasis}, 8'h07, "S5 $2001 emphasis bits captured");
        check_true(grayscale == 1'b1, "S5 $2001 grayscale bit captured");

        // 读侧镜像：地址 0x10 必须返回镜像后的 0x00 表项。
        // Read-side mirror: address 0x10 must return the mirrored 0x00 entry.
        blank_i = 1'b0;
        ext_i   = 4'h0;
        ext4_bg_sprite_i = 1'b1;
        @(posedge phi2); #20;
        check6(pixel_index, 6'h2A, "S5 read of $3F10 mirrors $3F00 entry");

        if (errors == e0)
            $display("[SCENARIO 5] PASS");
        else
            $display("[SCENARIO 5] FAIL");

        // --------------------------------------------------------------
        $display("");
        $display("=== SCENARIO 6: EXT pixel capture + palette lookup ===");
        e0 = errors;

        // 填充背景表项 0x05 与精灵表项 0x15。
        // Populate background entry 0x05 and sprite entry 0x15.
        cpu_write(3'b000, 8'h00);
        pal_write(14'h3F05, 6'h16);
        pal_write(14'h3F15, 6'h27);
        check6(dut.u_palette.pal_mem[5],  6'h16, "S6 palette[0x05] = 0x16");
        check6(dut.u_palette.pal_mem[21], 6'h27, "S6 palette[0x15] = 0x27");

        blank_i = 1'b0;
        ext_i   = 4'h5;
        ext4_bg_sprite_i = 1'b0;
        @(posedge phi2); #20;
        check_true(pixel_palette_addr == 5'h05, "S6 EXT4=0 -> palette addr 0x05");
        check6(pixel_index, 6'h16, "S6 background pixel index = 0x16");
        check_true(pixel_valid == 1'b1, "S6 pixel valid while blank=0");

        ext_i   = 4'h5;
        ext4_bg_sprite_i = 1'b1;
        @(posedge phi2); #20;
        check_true(pixel_palette_addr == 5'h15, "S6 EXT4=1 -> palette addr 0x15");
        check6(pixel_index, 6'h27, "S6 sprite pixel index = 0x27");

        // 寄存器时序：在 phi2 边沿之后立刻改变 EXT；输出必须保持上一个像素，
        // 直到下一个边沿。
        // Register timing: change EXT just after a phi2 edge; output must hold
        // the previous pixel until the next edge.
        @(posedge phi2); #1;
        ext_i = 4'h2;
        ext4_bg_sprite_i = 1'b0;
        #20;
        check6(pixel_index, 6'h27, "S6 EXT capture is registered (holds old pixel)");
        @(posedge phi2); #20;
        check_true(pixel_palette_addr == 5'h02, "S6 next edge captures EXT=0x2");
        check6(pixel_index, 6'h21, "S6 palette[0x02] = 0x21");

        blank_i = 1'b1;
        @(posedge phi2); #20;
        check_true(pixel_valid == 1'b0, "S6 blank=1 deasserts pixel_valid");

        if (errors == e0)
            $display("[SCENARIO 6] PASS");
        else
            $display("[SCENARIO 6] FAIL");

        // --------------------------------------------------------------
        $display("");
        $display("=== SCENARIO 7: $2006 ordering + mid-sequence inc change ===");
        e0 = errors;

        cpu_write(3'b000, 8'h00);       // +1
        cpu_write(3'b110, 8'h3F);
        cpu_write(3'b110, 8'h00);
        cpu_write(3'b111, 8'h0A);       // palette[0x00] = 0x0A, addr -> $3F01
        check6(dut.u_palette.pal_mem[0], 6'h0A, "S7 first $3F00 write = 0x0A");
        check_true(dut.u_palette.ppu_addr == 14'h3F01,
                   "S7 $2006 low/high ordering produced $3F01");

        cpu_write(3'b000, 8'h04);       // switch to +32
        cpu_write(3'b111, 8'h0B);       // palette[0x01] = 0x0B, addr -> $3F21
        check6(dut.u_palette.pal_mem[1], 6'h0B, "S7 mid-sequence +32 write = 0x0B");
        check_true(dut.u_palette.ppu_addr == 14'h3F21,
                   "S7 mid-sequence $2000 change selected +32");

        // 回到 +1，并确认一对新的 $2006 写有效。
        // Return to +1 and confirm a fresh $2006 pair works.
        cpu_write(3'b000, 8'h00);
        cpu_write(3'b110, 8'h3F);
        cpu_write(3'b110, 8'h02);
        cpu_write(3'b111, 8'h0C);
        check6(dut.u_palette.pal_mem[2], 6'h0C, "S7 fresh $2006 pair writes 0x02");
        check_true(dut.u_palette.ppu_addr == 14'h3F03,
                   "S7 returned to +1 increment");

        blank_i = 1'b0;
        ext_i   = 4'h2;
        ext4_bg_sprite_i = 1'b0;
        @(posedge phi2); #20;
        check6(pixel_index, 6'h0C, "S7 EXT pixel uses updated palette[0x02]");

        if (errors == e0)
            $display("[SCENARIO 7] PASS");
        else
            $display("[SCENARIO 7] FAIL");

        // --------------------------------------------------------------
        $display("");
        $display("================================================================");
        $display(" SUMMARY: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display(" RESULT: ALL SEVEN SCENARIOS PASS (EXT_OUT_BIT=%0d)", EXT_OUT_BIT);
        else
            $display(" RESULT: FAIL (EXT_OUT_BIT=%0d)", EXT_OUT_BIT);
        $display("================================================================");

        #500;
        $finish;
    end

    // 全局看门狗：绝不让坏掉的握手把仿真永远挂住。
    // Global watchdog: never let a broken handshake hang the run forever.
    initial begin
        #700000;
        $display("GLOBAL TIMEOUT: simulation exceeded 700 us");
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
