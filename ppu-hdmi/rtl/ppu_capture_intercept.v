// AI-assisted; see NOTICE.md
`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// ppu_capture_intercept.v
//
// 「PPU 采集」改造中，PPU 总线转接板（interposer）的顶层。
// Top level of the PPU-bus interposer for the "PPU capture" mod.
//
// 修正后的架构（见 REPORT.md）：
// CORRECTED ARCHITECTURE (see REPORT.md):
//   2C02 并不会把像素数据放到 CPU 数据总线 D0-D7 上。把 $2000 的 bit 6 置 1
//   会让 EXT0..EXT3 引脚进入输出（主）模式；这四个引脚随后承载当前像素
//   调色板地址的低位部分。调色板地址的第 5 位（背景 / 精灵）不在 EXT 上，
//   需要由外部比较器从 VOUT 恢复。调色板 RAM 在芯片内部，因此这里通过
//   监听 CPU 对 $2006/$2007 的写来维护它的影子副本。
//   The 2C02 does not put pixel data on the CPU data bus D0-D7.  Setting
//   $2000 bit 6 = 1 puts the EXT0..EXT3 pins into output (master) mode; those
//   four pins then carry the low part of the current pixel's palette address.
//   The fifth palette-address bit (background vs sprite) is not on EXT and is
//   recovered from VOUT by external comparators.  Palette RAM is internal, so
//   its contents are shadowed here from CPU writes to $2006/$2007.
//
//   CPU 总线 ---> [本 FPGA] ---> 2C02 寄存器总线
//   CPU bus  --->  [this FPGA]  --->  2C02 register bus
//                         |
//                         +-- $2000 守卫 / 可选注入 / $2000 guard / optional injection
//                         +-- 调色板 RAM 影子 / palette-RAM shadow
//
//   EXT0..3 ---> 采集寄存器 ---> {ext4, EXT} -> 调色板影子 -> 6 位表项
//   EXT0..3 ---> capture regs ---> {ext4, EXT} -> palette shadow -> 6-bit entry
//
// 写守卫会在每次 CPU 写 $2000 时强制置上 EXT_OUT_BIT（默认 6），
// 这样游戏代码无法关掉 EXT 输出。另有一次性的注入逻辑，用同样置位的
// 位写入 ctrl_shadow，同时保留 PPUCTRL 的其它位。
// The write guard forces EXT_OUT_BIT (default 6) on every CPU write to $2000,
// so game code cannot turn the EXT outputs off.  A separate one-shot injection
// writes ctrl_shadow with the same bit set, preserving the other PPUCTRL bits.
//
// 重要硬件安全：
// IMPORTANT HARDWARE SAFETY:
//   在原装机上 EXT0..EXT3 是被接地的。当它们仍然接地时把它们当输出去驱动，
//   可能把 PPU 烧坏。在启用输出模式之前，板子必须先把 EXT0..EXT3 与主机
//   隔离（插座 / 转接板 / 割线）。参见 REPORT.md。
//   On a stock console the EXT0..EXT3 pins are tied to ground.  Driving them as
//   outputs while they are still connected to ground can short the PPU.  The
//   board must isolate EXT0..EXT3 from the console (socket/interposer or trace
//   cut) before enabling output mode.  See REPORT.md.
//
// PPU 数据总线用输出使能（ppu_d_oe）建模，就像板上真有双向收发器一样。
// CPU 侧的读数据由 ppu_d_in 返回。
// The PPU data bus is modelled with an output-enable (ppu_d_oe), as it would
// be on a board with a real bidirectional transceiver.  The CPU-side read data
// is returned from ppu_d_in.
// -----------------------------------------------------------------------------
`default_nettype none

module ppu_capture_intercept #(
    parameter integer EXT_OUT_BIT = 6
) (
    input  wire       clk,          // FPGA 时钟，本仿真中为 4 倍 phi2 / FPGA clock, 4x phi2 in this simulation
    input  wire       rst_n,
    input  wire       phi2,         // PPU 点时钟 / 像素时钟（标称 5.369 MHz）/ PPU dot / pixel clock (5.369 MHz nominal)

    // CPU 侧的 PPU 寄存器总线（$2000-$3FFF 已译码）
    // CPU-side PPU register bus ($2000-$3FFF already decoded)
    input  wire       cpu_cs_n,
    input  wire       cpu_rw,       // 1 = 读，0 = 写 / 1 = read, 0 = write
    input  wire [2:0] cpu_a,
    input  wire [7:0] cpu_d_in,
    output wire [7:0] cpu_d_out,
    output wire       cpu_d_oe,

    // PPU 侧寄存器总线 / PPU-side register bus
    output wire       ppu_cs_n,
    output wire       ppu_rw,
    output wire [2:0] ppu_a,
    output wire [7:0] ppu_d_out,
    output wire       ppu_d_oe,
    input  wire [7:0] ppu_d_in,

    // EXT 像素总线与比较器恢复的时序信号。
    // ext4_bg_sprite_i: 0 = 背景半区（$3F00-$3F0F），
    //                   1 = 精灵半区（$3F10-$3F1F）。
    // EXT pixel bus and comparator-derived timing.
    // ext4_bg_sprite_i: 0 = background half ($3F00-$3F0F),
    //                   1 = sprite half     ($3F10-$3F1F).
    input  wire [3:0] ext_i,
    input  wire       ext4_bg_sprite_i,
    input  wire       hsync_i,
    input  wire       vsync_i,
    input  wire       blank_i,

    // 采集到的像素结果 / Captured pixel result
    output wire [5:0] pixel_index_o,
    output wire [4:0] pixel_palette_addr_o,
    output wire       pixel_valid_o,
    output wire [2:0] emphasis_o,
    output wire       grayscale_o,

    // 控制与状态 / Control and status
    input  wire       capture_en,
    input  wire       inject_req,
    output wire       inject_ack,
    output wire       inject_busy,
    output wire       inject_collision,
    output wire [7:0] ctrl_shadow,
    output wire       ext_out_bit_held
);

    wire [7:0] ext_out_mask = (8'h01 << EXT_OUT_BIT);

    // ------------------------------------------------------------------
    // 写守卫 / $2000 影子 / Write guard / $2000 shadow
    // ------------------------------------------------------------------
    wire [7:0] guard_data;
    wire       cpu_write;
    wire       ext_out_bit_shadow;

    ppu_write_guard #(
        .EXT_OUT_BIT (EXT_OUT_BIT)
    ) u_guard (
        .clk                (clk),
        .rst_n              (rst_n),
        .cpu_cs_n           (cpu_cs_n),
        .cpu_rw             (cpu_rw),
        .cpu_a              (cpu_a),
        .cpu_d_in           (cpu_d_in),
        .capture_en         (capture_en),
        .ctrl_shadow        (ctrl_shadow),
        .cpu_write          (cpu_write),
        .ppu_write_data     (guard_data),
        .ext_out_bit_shadow (ext_out_bit_shadow)
    );

    // ------------------------------------------------------------------
    // 注入主机（可选的上电辅助功能）
    // Injection master (optional startup helper)
    // ------------------------------------------------------------------
    wire [7:0] inject_data = ctrl_shadow | ext_out_mask;
    wire       inject_go   = inject_req & capture_en;
    wire       inj_active;

    ppu_injector #(
        .HOLD_CLKS (1)
    ) u_inject (
        .clk          (clk),
        .rst_n        (rst_n),
        .phi2         (phi2),
        .inject_req   (inject_go),
        .bus_idle     (cpu_cs_n),
        .inject_data  (inject_data),
        .active       (inj_active),
        .ack          (inject_ack),
        .busy         (inject_busy),
        .collision    (inject_collision)
    );

    // 如果 CPU 在注入进行中发起了 PPU 访问，就立即在同一条组合通路上把
    // 总线交还给 CPU。注入器下一个时钟看到 bus_idle=0 便中止。这是防止
    // 总线争用的互锁，而不是 CPU 等待状态发生器。
    // If the CPU starts a PPU access while an injection is in progress, hand
    // the bus back to the CPU on the same combinational path.  The injector's
    // next clock sees bus_idle=0 and aborts.  This is the anti-contention
    // interlock; it is not a CPU wait-state generator.
    wire inj_drive = inj_active & cpu_cs_n;

    assign ppu_cs_n = inj_drive ? 1'b0 : cpu_cs_n;
    assign ppu_rw   = inj_drive ? 1'b0 : cpu_rw;
    assign ppu_a    = inj_drive ? 3'b000 : cpu_a;

    // 注入期间，驱动保存下来的 PPUCTRL 值（其中 EXT 输出位已置位）。在 CPU
    // 写周期里，驱动经过守卫的 CPU 字节。在读周期里，完全释放 PPU 数据总线。
    // During an injection, drive the saved PPUCTRL value with the EXT-output
    // bit set.  During a CPU write, drive the guarded CPU byte.  During a
    // read, release the PPU data bus entirely.
    assign ppu_d_out = inj_drive ? inject_data
                     : cpu_write ? guard_data
                     : 8'h00;
    assign ppu_d_oe  = inj_drive | cpu_write;

    // 读通路：PPU 驱动 ppu_d_in，直接透传回 CPU。
    // Read path: the PPU drives ppu_d_in; pass it straight back to the CPU.
    assign cpu_d_out = ppu_d_in;
    assign cpu_d_oe  = ~cpu_cs_n & cpu_rw;

    assign ext_out_bit_held = ctrl_shadow[EXT_OUT_BIT];

    // ------------------------------------------------------------------
    // 调色板 RAM 影子（CPU 侧）/ Palette RAM shadow (CPU side)
    // ------------------------------------------------------------------
    wire [5:0] palette_data;
    wire [4:0] pixel_palette_addr;
    wire [7:0] mask_shadow_unused;

    ppu_palette_shadow u_palette (
        .clk          (clk),
        .rst_n        (rst_n),
        .cpu_cs_n     (cpu_cs_n),
        .cpu_rw       (cpu_rw),
        .cpu_a        (cpu_a),
        .cpu_d_in     (cpu_d_in),
        .ctrl_shadow  (ctrl_shadow),
        .mask_shadow  (mask_shadow_unused),
        .emphasis     (emphasis_o),
        .grayscale    (grayscale_o),
        .pal_addr_i   (pixel_palette_addr),
        .pal_data_o   (palette_data)
    );

    // ------------------------------------------------------------------
    // EXT 像素采集（像素时钟域）/ EXT pixel capture (pixel-clock domain)
    // ------------------------------------------------------------------
    wire [3:0] ext_pixel;
    wire       ext4_bg_sprite;
    wire       ext_hsync;
    wire       ext_vsync;
    wire       ext_blank;

    ppu_ext_capture u_ext_capture (
        .pix_clk           (phi2),
        .rst_n             (rst_n),
        .ext_i             (ext_i),
        .ext4_bg_sprite_i  (ext4_bg_sprite_i),
        .hsync_i           (hsync_i),
        .vsync_i           (vsync_i),
        .blank_i           (blank_i),
        .ext_pixel         (ext_pixel),
        .ext4_bg_sprite    (ext4_bg_sprite),
        .hsync             (ext_hsync),
        .vsync             (ext_vsync),
        .blank             (ext_blank)
    );

    // ------------------------------------------------------------------
    // 调色板查表 / 像素输出 / Palette lookup / pixel output
    // ------------------------------------------------------------------
    ppu_pixel_out u_pixel_out (
        .ext_pixel        (ext_pixel),
        .ext4_bg_sprite   (ext4_bg_sprite),
        .palette_data     (palette_data),
        .blank            (ext_blank),
        .palette_addr     (pixel_palette_addr),
        .pixel_index      (pixel_index_o),
        .pixel_valid      (pixel_valid_o)
    );

    assign pixel_palette_addr_o = pixel_palette_addr;

    // 让这些本来没用的信号在综合 lint 里保持可见。
    // Keep otherwise-unused signals visible in synthesis lint.
    wire unused_shadow = ext_out_bit_shadow;
    wire unused_hsync  = ext_hsync;
    wire unused_vsync  = ext_vsync;
    wire unused_mask   = |mask_shadow_unused;

endmodule

`default_nettype wire
