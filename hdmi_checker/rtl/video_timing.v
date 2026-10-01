// ---------------------------------------------------------------------------
// video_timing : 비디오 타이밍 생성기 (기본값 640x480 @ 60Hz, 픽셀클럭 25 MHz)
//
//   한 라인 = ACTIVE -> FRONT PORCH -> SYNC -> BACK PORCH
//   출력은 모두 레지스터 출력 (x, y, de, hsync, vsync 가 같은 클럭에 정렬됨)
// ---------------------------------------------------------------------------
module video_timing #(
    parameter H_ACTIVE = 640,
    parameter H_FP     = 16,
    parameter H_SYNC   = 96,
    parameter H_BP     = 48,
    parameter V_ACTIVE = 480,
    parameter V_FP     = 10,
    parameter V_SYNC   = 2,
    parameter V_BP     = 33,
    parameter HS_POL   = 0,     // 0: active-low sync, 1: active-high sync
    parameter VS_POL   = 0
) (
    input  wire        clk,
    input  wire        rst,
    output reg  [11:0] x,
    output reg  [11:0] y,
    output reg         de,      // 화면 표시 구간
    output reg         hsync,
    output reg         vsync
);
    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    reg [11:0] hcnt;
    reg [11:0] vcnt;

    // 수평/수직 카운터
    always @(posedge clk) begin
        if (rst) begin
            hcnt <= 0;
            vcnt <= 0;
        end else if (hcnt == H_TOTAL - 1) begin
            hcnt <= 0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 12'd0 : vcnt + 1'b1;
        end else begin
            hcnt <= hcnt + 1'b1;
        end
    end

    wire hs_active = (hcnt >= H_ACTIVE + H_FP) && (hcnt < H_ACTIVE + H_FP + H_SYNC);
    wire vs_active = (vcnt >= V_ACTIVE + V_FP) && (vcnt < V_ACTIVE + V_FP + V_SYNC);

    always @(posedge clk) begin
        if (rst) begin
            x     <= 0;
            y     <= 0;
            de    <= 1'b0;
            hsync <= ~HS_POL[0];
            vsync <= ~VS_POL[0];
        end else begin
            x     <= hcnt;
            y     <= vcnt;
            de    <= (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);
            hsync <= HS_POL[0] ? hs_active : ~hs_active;
            vsync <= VS_POL[0] ? vs_active : ~vs_active;
        end
    end
endmodule
