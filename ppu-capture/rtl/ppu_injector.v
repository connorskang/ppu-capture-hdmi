// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// ppu_injector.v
//
// 一次性的 PPU $2000 写主机。它会等到 CPU 没有占用 PPU 寄存器总线时，
// 在 PPU 侧发起一个写周期，并在 2C02 的采样边沿之后再多保持一个 FPGA
// 时钟的保持时间，然后释放总线。
// One-shot PPU $2000 write master.  It waits until the CPU is not using the
// PPU register bus, drives a single write cycle on the PPU side, and releases
// the bus after the 2C02 sampling edge plus one FPGA clock of hold time.
//
// 仿真中使用的时序模型：
// Timing model used for the simulation:
//   * phi2 是 PPU 点时钟（标称 21.47727 MHz / 4 = 5.3693175 MHz）。
//   * phi2 is the PPU dot clock (nominally 21.47727 MHz / 4 = 5.3693175 MHz).
//   * 2C02 在 phi2 的上升沿锁存寄存器写。
//   * The 2C02 latches register writes on the rising edge of phi2.
//   * 本 testbench 中 FPGA 时钟是 phi2 的 4 倍。
//   * The FPGA clock is 4x phi2 in this testbench.
//   * 写操作在 phi2 为高、且已经高了至少一个 FPGA 时钟时发起。因此下一个
//     phi2 上升沿至少还差半个 phi2 周期（标称 >= 93 ns），这就是建立裕量。
//   * A write is launched while phi2 is high and has been high for at least
//     one FPGA clock.  The next phi2 rising edge is therefore at least half a
//     phi2 period away (>= 93 ns nominal), which is the setup margin.
//   * 观察到采样边沿之后，再过一个 FPGA 时钟才释放总线，从而给出至少一个
//     FPGA 时钟（标称 >= 46 ns）的保持时间。
//   * The bus is released one FPGA clock after the sampling edge is observed,
//     giving at least one FPGA clock (>= 46 ns nominal) of hold time.
//
// 注入器故意做得很保守：它不会在 CPU 正在访问 PPU 时凭空造出一个总线周期。
// 如果注入已经开始后 CPU 才发起访问，顶层会立刻把总线交还 CPU，本模块则
// 拉高 inject_collision。这能避免电气争用，但无法撤销 PPU 可能已经采样到的
// 那次写；这个真实硬件上的限制见 REPORT.md。
// The injector is intentionally conservative: it does not fabricate a bus
// cycle while the CPU is accessing the PPU.  If the CPU begins an access after
// the injection has started, the top level immediately hands the bus back to
// the CPU and this module raises inject_collision.  That prevents electrical
// contention but cannot undo a write that the PPU may already have sampled;
// see REPORT.md for the real-hardware limitation.
// -----------------------------------------------------------------------------
`default_nettype none

module ppu_injector #(
    parameter integer HOLD_CLKS = 1
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       phi2,          // PPU 点时钟，标称 5.369 MHz / PPU dot clock, 5.369 MHz nominal

    input  wire       inject_req,    // 一个或多个时钟，内部会锁存 / one or more clocks; internally latched
    input  wire       bus_idle,      // 1 = CPU 没有选中 PPU / 1 = CPU is not selecting the PPU
    input  wire [7:0] inject_data,   // 要写入 $2000 的字节 / byte to write to $2000

    output reg        active,         // 本模块占用 PPU 总线期间为 1 / 1 while this module owns the PPU bus
    output reg        ack,            // 单时钟宽度的完成脉冲 / one-clock completion pulse
    output reg        busy,           // 请求挂起或周期进行中 / request pending or cycle in progress
    output reg        collision       // 粘滞到下一个请求 / sticky until the next request
);

    localparam [1:0] ST_IDLE   = 2'd0;
    localparam [1:0] ST_ASSERT = 2'd1;
    localparam [1:0] ST_HOLD   = 2'd2;
    localparam [3:0] HOLD_INIT = HOLD_CLKS;

    reg [1:0] state;
    reg       phi2_d;
    reg       req_pending;
    reg [7:0] data_latched;
    reg [3:0] hold_count;

    // phi2 为高且已稳定至少一个 clk。在这里发起，意味着下一个上升沿
    // 至少还差半个 phi2 周期。
    // phi2 high and stable for at least one clk.  Launching here means the
    // next rising edge is at least half a phi2 period away.
    wire launch_window = phi2 & phi2_d;

    // 在 clk 域观察到的 phi2 上升沿。PPU 在同一个物理边沿采样；看到这个
    // 边沿之后总线再保持 HOLD_CLKS 个时钟。
    // phi2 rising edge, as observed in the clk domain.  The PPU samples on the
    // same physical edge; the bus is held for HOLD_CLKS after this is seen.
    wire phi2_rise = phi2 & ~phi2_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            phi2_d       <= 1'b0;
            req_pending  <= 1'b0;
            data_latched <= 8'h00;
            hold_count   <= 4'd0;
            active       <= 1'b0;
            ack          <= 1'b0;
            busy         <= 1'b0;
            collision    <= 1'b0;
        end else begin
            phi2_d <= phi2;
            ack    <= 1'b0;

            if (inject_req) begin
                req_pending <= 1'b1;
                collision   <= 1'b0;
            end

            case (state)
                ST_IDLE: begin
                    active <= 1'b0;
                    if (req_pending && bus_idle && launch_window) begin
                        active       <= 1'b1;
                        data_latched <= inject_data;
                        req_pending  <= 1'b0;
                        state        <= ST_ASSERT;
                    end
                end

                ST_ASSERT: begin
                    active <= 1'b1;
                    if (!bus_idle) begin
                        // CPU 抢到了总线，立即释放。顶层也会以组合方式把
                        // CPU 直接接通。
                        // CPU won the bus; release immediately.  The top level
                        // also muxes the CPU through combinationally.
                        active    <= 1'b0;
                        state     <= ST_IDLE;
                        collision <= 1'b1;
                    end else if (phi2_rise) begin
                        hold_count <= HOLD_INIT;
                        state      <= ST_HOLD;
                    end
                end

                ST_HOLD: begin
                    active <= 1'b1;
                    if (hold_count <= 4'd1) begin
                        active <= 1'b0;
                        ack    <= 1'b1;
                        state  <= ST_IDLE;
                    end else begin
                        hold_count <= hold_count - 4'd1;
                    end
                end

                default: begin
                    state  <= ST_IDLE;
                    active <= 1'b0;
                end
            endcase

            busy <= (state != ST_IDLE) || req_pending;
        end
    end

endmodule

`default_nettype wire
