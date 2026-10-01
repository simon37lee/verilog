// ---------------------------------------------------------------------------
// hdmi_core : 타이밍 생성 -> 체크보드 + 움직이는 공 -> TMDS 인코딩 (벤더 독립 부분)
//
//   출력은 픽셀 클럭마다 바뀌는 채널별 10비트 TMDS 워드.
//   채널 0(Blue) 의 컨트롤 비트에 hsync / vsync 를 실어 보낸다.
//   (데이터 아일랜드/오디오 없는 DVI 방식이며, HDMI 모니터와 호환된다)
// ---------------------------------------------------------------------------
module hdmi_core #(
    parameter SQUARE_LOG2 = 5,
    parameter MOVE_CYCLES = 2_500_000    // 공 이동 주기 (0.1 s @ 25 MHz)
) (
    input  wire       clk_pix,
    input  wire       rst,
    output wire [9:0] tmds_ch0,   // Blue  + hsync/vsync
    output wire [9:0] tmds_ch1,   // Green
    output wire [9:0] tmds_ch2    // Red
);
    wire [11:0] x, y;
    wire        de_t, hs_t, vs_t;

    video_timing u_timing (
        .clk   (clk_pix),
        .rst   (rst),
        .x     (x),
        .y     (y),
        .de    (de_t),
        .hsync (hs_t),
        .vsync (vs_t)
    );

    // 표시 구간이 끝나는 순간(마지막 라인 다음 줄 시작) = 공 위치를 바꿔도 안전한 시점
    localparam H_ACTIVE = 640;
    localparam V_ACTIVE = 480;
    wire frame_tick = (x == 0) && (y == V_ACTIVE);

    wire [6:0] ball_cx, ball_cy;

    ball_mover #(
        .GRID_W      (H_ACTIVE >> SQUARE_LOG2),
        .GRID_H      (V_ACTIVE >> SQUARE_LOG2),
        .MOVE_CYCLES (MOVE_CYCLES)
    ) u_ball (
        .clk        (clk_pix),
        .rst        (rst),
        .frame_tick (frame_tick),
        .cx         (ball_cx),
        .cy         (ball_cy)
    );

    wire [7:0] r, g, b;
    wire       de, hs, vs;

    checkerboard #(.SQUARE_LOG2(SQUARE_LOG2)) u_pattern (
        .clk      (clk_pix),
        .x        (x),
        .y        (y),
        .de_in    (de_t),
        .hsync_in (hs_t),
        .vsync_in (vs_t),
        .ball_cx  (ball_cx),
        .ball_cy  (ball_cy),
        .r        (r),
        .g        (g),
        .b        (b),
        .de       (de),
        .hsync    (hs),
        .vsync    (vs)
    );

    tmds_encoder u_enc_b (.clk(clk_pix), .rst(rst), .d(b), .c0(hs),   .c1(vs),   .de(de), .q_out(tmds_ch0));
    tmds_encoder u_enc_g (.clk(clk_pix), .rst(rst), .d(g), .c0(1'b0), .c1(1'b0), .de(de), .q_out(tmds_ch1));
    tmds_encoder u_enc_r (.clk(clk_pix), .rst(rst), .d(r), .c0(1'b0), .c1(1'b0), .de(de), .q_out(tmds_ch2));
endmodule
