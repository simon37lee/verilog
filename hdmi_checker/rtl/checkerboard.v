// ---------------------------------------------------------------------------
// checkerboard : 체크보드 패턴 + 체스칸 위의 동그라미(공)
//
//   한 칸 크기 = 2^SQUARE_LOG2 픽셀 (기본 32x32)
//   x, y 의 SQUARE_LOG2 번째 비트를 XOR 하면 칸마다 색이 번갈아 바뀐다.
//   (ball_cx, ball_cy) 칸의 중앙에 반지름 BALL_R 픽셀의 원을 그린다.
//   1 클럭 지연되므로 sync/de 도 함께 1 클럭 지연시켜 정렬을 맞춘다.
// ---------------------------------------------------------------------------
module checkerboard #(
    parameter        SQUARE_LOG2 = 5,
    parameter        BALL_R      = 12,
    parameter [23:0] COLOR_A     = 24'hFFFFFF,  // RGB (흰색)
    parameter [23:0] COLOR_B     = 24'h000000,  // RGB (검정)
    parameter [23:0] BALL_COLOR  = 24'hFF0000   // RGB (빨강)
) (
    input  wire        clk,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de_in,
    input  wire        hsync_in,
    input  wire        vsync_in,
    input  wire [6:0]  ball_cx,
    input  wire [6:0]  ball_cy,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg         de,
    output reg         hsync,
    output reg         vsync
);
    localparam SQ = 1 << SQUARE_LOG2;

    wire sel = x[SQUARE_LOG2] ^ y[SQUARE_LOG2];

    // 칸 안에서의 위치를 칸 중심 기준 좌표로 (2배 스케일 -> 정수로 정확한 중심)
    wire        [SQUARE_LOG2-1:0] lx = x[SQUARE_LOG2-1:0];
    wire        [SQUARE_LOG2-1:0] ly = y[SQUARE_LOG2-1:0];
    wire signed [9:0]  ddx  = $signed({3'b0, lx, 1'b0}) - (SQ - 1);
    wire signed [9:0]  ddy  = $signed({3'b0, ly, 1'b0}) - (SQ - 1);
    wire        [19:0] dist2 = ddx * ddx + ddy * ddy;

    wire in_ball_square = (x[11:SQUARE_LOG2] == ball_cx) && (y[11:SQUARE_LOG2] == ball_cy);
    wire in_ball        = in_ball_square && (dist2 <= 4 * BALL_R * BALL_R);

    always @(posedge clk) begin
        {r, g, b} <= !de_in  ? 24'h000000 :
                     in_ball ? BALL_COLOR :
                     sel     ? COLOR_B    : COLOR_A;
        de        <= de_in;
        hsync     <= hsync_in;
        vsync     <= vsync_in;
    end
endmodule
