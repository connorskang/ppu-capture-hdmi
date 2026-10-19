// AI-assisted; see NOTICE.md
// 参数化的 CEA-861 视频时序发生器。
// Parameterised CEA-861 video timing generator.
//
// 默认值 = VIC 16，1920x1080p @ 59.94/60 Hz（最初的 1080p30 构建原样使用这些默认值）：
// Defaults = VIC 16, 1920x1080p @ 59.94/60 Hz (the original 1080p30 build uses
// these defaults unchanged):
//   H: 有效 1920 | 前肩 88 | 同步 44 | 后肩 148 | 总计 2200
//   H: active 1920 | front porch 88 | sync 44 | back porch 148 | total 2200
//   V: 有效 1080 | 前肩  4 | 同步  5 | 后肩  36 | 总计 1125
//   V: active 1080 | front porch  4 | sync  5 | back porch  36 | total 1125
//
// 720p60 (VIC 4) 通过在顶层覆盖参数来选择：
// 720p60 (VIC 4) is selected by overriding the parameters in the top level:
//   H: 有效 1280 | 前肩 110 | 同步 40 | 后肩 220 | 总计 1650
//   H: active 1280 | front porch 110 | sync 40 | back porch 220 | total 1650
//   V: 有效  720 | 前肩   5 | 同步  5 | 后肩  20 | 总计  750
//   V: active  720 | front porch   5 | sync  5 | back porch  20 | total  750
//   74.25e6 / (1650 * 750) = 60.000 Hz
//
// 这两种格式的行、场同步极性都是正极性。
// Both sync polarities are positive for both of these formats.
module hdmi_timing #(
    parameter [11:0] H_ACTIVE = 12'd1920,
    parameter [11:0] H_FP     = 12'd88,
    parameter [11:0] H_SYNC   = 12'd44,
    parameter [11:0] H_BP     = 12'd148,
    parameter [11:0] V_ACTIVE = 12'd1080,
    parameter [11:0] V_FP     = 12'd4,
    parameter [11:0] V_SYNC   = 12'd5,
    parameter [11:0] V_BP     = 12'd36
) (
    input  wire        clk_pixel,
    input  wire        reset,
    output reg  [11:0] cx,
    output reg  [11:0] cy,
    output wire        hsync,
    output wire        vsync,
    output wire        active
);

    localparam [11:0] H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 2200 / 1650
    localparam [11:0] V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 1125 /  750

    always @(posedge clk_pixel) begin
        if (reset) begin
            cx <= 12'd0;
            cy <= 12'd0;
        end else if (cx == H_TOTAL - 12'd1) begin
            cx <= 12'd0;
            cy <= (cy == V_TOTAL - 12'd1) ? 12'd0 : cy + 12'd1;
        end else begin
            cx <= cx + 12'd1;
        end
    end

    assign hsync  = (cx >= H_ACTIVE + H_FP) && (cx < H_ACTIVE + H_FP + H_SYNC);
    assign vsync  = (cy >= V_ACTIVE + V_FP) && (cy < V_ACTIVE + V_FP + V_SYNC);
    assign active = (cx < H_ACTIVE) && (cy < V_ACTIVE);

endmodule
