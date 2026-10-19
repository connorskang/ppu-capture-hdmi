// AI-assisted; see NOTICE.md
// 简单的静态测试图案：在有效区域内画 8 条等宽的纵向彩条（每条占 H_ACTIVE 的
// 八分之一），有效区域之外为黑色。
// Simple static test pattern: 8 equal vertical colour bars across the active
// area (one eighth of H_ACTIVE each), black outside the active area.
//
// H_ACTIVE 默认 1920，因此 1080p30 构建保持不变（每条 240 px）；
// 720p60 顶层把它覆盖为 1280（每条 160 px）。
// H_ACTIVE defaults to 1920 so the 1080p30 build is unchanged (240 px bars);
// the 720p60 top overrides it to 1280 (160 px bars).
module pattern_gen #(
    parameter [11:0] H_ACTIVE = 12'd1920
) (
    input  wire [11:0] cx,
    input  wire [11:0] cy,
    input  wire        active,
    output reg  [23:0] rgb
);

    localparam [11:0] BAR = H_ACTIVE / 12'd8;   // 1920 时 240，1280 时 160 / 240 @1920, 160 @1280

// 类似 SMPTE 的顺序：白、黄、青、绿、品红、红、蓝、黑
// SMPTE-ish ordering: white, yellow, cyan, green, magenta, red, blue, black
localparam [23:0] C0 = 24'hFFFFFF;
localparam [23:0] C1 = 24'hFFFF00;
localparam [23:0] C2 = 24'h00FFFF;
localparam [23:0] C3 = 24'h00FF00;
localparam [23:0] C4 = 24'hFF00FF;
localparam [23:0] C5 = 24'hFF0000;
localparam [23:0] C6 = 24'h0000FF;
localparam [23:0] C7 = 24'h000000;

always @(*) begin
    if (!active)
        rgb = 24'h000000;
    else if (cx < BAR * 12'd1)
        rgb = C0;
    else if (cx < BAR * 12'd2)
        rgb = C1;
    else if (cx < BAR * 12'd3)
        rgb = C2;
    else if (cx < BAR * 12'd4)
        rgb = C3;
    else if (cx < BAR * 12'd5)
        rgb = C4;
    else if (cx < BAR * 12'd6)
        rgb = C5;
    else if (cx < BAR * 12'd7)
        rgb = C6;
    else
        rgb = C7;
end

endmodule
