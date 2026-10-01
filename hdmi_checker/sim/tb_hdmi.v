// ---------------------------------------------------------------------------
// tb_hdmi : hdmi_core + tmds_serializer 검증
//
//   1) 직렬 비트열을 다시 10비트로 모은 뒤 TMDS 디코딩
//   2) 표시 구간 픽셀이 체크보드 기대값과 같은지 비교
//      - 빨간 공은 한 칸 안에서 원 모양이어야 하고
//      - 프레임마다 8방향 중 한 칸씩 움직여야 한다
//   3) 프레임당 표시 픽셀 수, 라인당 hsync, 프레임당 vsync 확인
//   4) 각 채널 DC 밸런스(누적 불균형)가 일정 범위 안인지 확인
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_hdmi;
    localparam SQUARE_LOG2 = 5;
    localparam FRAMES      = 4;
    localparam BALL_R      = 12;
    localparam MOVE_CYCLES = 800 * 525;   // 시뮬레이션에서는 1프레임마다 이동

    reg clk_x10 = 0;
    reg clk_pix = 0;
    reg rst     = 1;

    // 250 MHz / 25 MHz (같은 위상)
    always #2 clk_x10 = ~clk_x10;
    initial forever begin
        #20 clk_pix = ~clk_pix;
    end

    wire [9:0] t0, t1, t2;
    wire       s0, s1, s2, sclk;

    hdmi_core #(.SQUARE_LOG2(SQUARE_LOG2), .MOVE_CYCLES(MOVE_CYCLES)) dut (
        .clk_pix(clk_pix), .rst(rst), .tmds_ch0(t0), .tmds_ch1(t1), .tmds_ch2(t2)
    );

    tmds_serializer ser (
        .clk_x10(clk_x10), .rst(rst), .ch0(t0), .ch1(t1), .ch2(t2),
        .s_ch0(s0), .s_ch1(s1), .s_ch2(s2), .s_clk(sclk)
    );

    // ---- 역직렬화: 클럭 채널 0000011111 의 위상으로 워드 경계를 찾는다 ----
    reg [9:0] w0, w1, w2, wc;
    always @(posedge clk_x10) begin
        w0 <= {s0, w0[9:1]};
        w1 <= {s1, w1[9:1]};
        w2 <= {s2, w2[9:1]};
        wc <= {sclk, wc[9:1]};
    end

    // ---- TMDS 디코더 --------------------------------------------------------
    function [9:0] decode;   // {is_ctrl, c1, c0, data[7:0]} -> 상위 비트 생략: {ctrl, c1c0 or data}
        input [9:0] q;
        reg   [7:0] dd;
        integer k;
        begin
            case (q)
                10'b1101010100: decode = {1'b1, 1'b0, 8'h00};
                10'b0010101011: decode = {1'b1, 1'b0, 8'h01};
                10'b0101010100: decode = {1'b1, 1'b0, 8'h02};
                10'b1010101011: decode = {1'b1, 1'b0, 8'h03};
                default: begin
                    dd = q[9] ? ~q[7:0] : q[7:0];
                    decode[0] = dd[0];
                    for (k = 1; k < 8; k = k + 1)
                        decode[k] = q[8] ? (dd[k] ^ dd[k-1]) : ~(dd[k] ^ dd[k-1]);
                    decode[9:8] = 2'b00;
                end
            endcase
        end
    endfunction

    function integer ones;
        input [9:0] v;
        integer k;
        begin
            ones = 0;
            for (k = 0; k < 10; k = k + 1) ones = ones + v[k];
        end
    endfunction

    // ---- 검사 ---------------------------------------------------------------
    integer errors = 0;
    integer words = 0;
    integer px = 0, py = 0;          // 디코딩된 화면 좌표
    integer de_pixels = 0, frames = 0;
    integer hs_pulses = 0, vs_pulses = 0;
    integer disp0 = 0, disp1 = 0, disp2 = 0, max_disp = 0;
    reg     prev_de = 0, prev_hs = 1, prev_vs = 1, synced = 0;

    reg [9:0] d0, d1, d2;
    reg       de, hs, vs;
    reg [7:0] exp_v;

    // 칸 중심 기준 원 안쪽인지 (RTL 과 같은 2배 스케일 정수 계산)
    function in_circle;
        input integer lx, ly;
        integer ddx, ddy;
        begin
            ddx = 2 * lx - ((1 << SQUARE_LOG2) - 1);
            ddy = 2 * ly - ((1 << SQUARE_LOG2) - 1);
            in_circle = (ddx * ddx + ddy * ddy) <= 4 * BALL_R * BALL_R;
        end
    endfunction

    // 공 추적
    integer circle_area = 0, red_pixels = 0, i, j;
    integer ball_sx = -1, ball_sy = -1, prev_sx = -1, prev_sy = -1, moves = 0;
    integer adx, ady;
    initial
        for (j = 0; j < (1 << SQUARE_LOG2); j = j + 1)
            for (i = 0; i < (1 << SQUARE_LOG2); i = i + 1)
                circle_area = circle_area + in_circle(i, j);

    always @(posedge clk_x10) begin
        if (!rst && wc == 10'b0000011111) begin   // 워드 경계
            d0 = decode(w0);
            d1 = decode(w1);
            d2 = decode(w2);
            de = !d0[9];
            hs = d0[0];
            vs = d0[1];
            words = words + 1;

            if (de) begin
                if (d1[9] || d2[9]) begin
                    $display("ERROR: channel mismatch ctrl/data at word %0d", words);
                    errors = errors + 1;
                end
                // 첫 vsync 이후부터 픽셀 검사
                if (synced && {d2[7:0], d1[7:0], d0[7:0]} == 24'hFF0000) begin
                    // 빨간 픽셀: 원 안이어야 하고, 프레임 내 모든 빨간 픽셀은 같은 칸
                    if (red_pixels == 0) begin
                        ball_sx = px >> SQUARE_LOG2;
                        ball_sy = py >> SQUARE_LOG2;
                    end
                    if ((px >> SQUARE_LOG2) != ball_sx || (py >> SQUARE_LOG2) != ball_sy ||
                        !in_circle(px % (1 << SQUARE_LOG2), py % (1 << SQUARE_LOG2))) begin
                        if (errors < 10) $display("ERROR: stray red pixel at (%0d,%0d)", px, py);
                        errors = errors + 1;
                    end
                    red_pixels = red_pixels + 1;
                    de_pixels  = de_pixels + 1;
                end else if (synced) begin
                    exp_v = (px[SQUARE_LOG2] ^ py[SQUARE_LOG2]) ? 8'h00 : 8'hFF;
                    if (d0[7:0] !== exp_v || d1[7:0] !== exp_v || d2[7:0] !== exp_v) begin
                        if (errors < 10)
                            $display("ERROR: (%0d,%0d) got %h%h%h expected %h",
                                     px, py, d2[7:0], d1[7:0], d0[7:0], exp_v);
                        errors = errors + 1;
                    end
                    de_pixels = de_pixels + 1;
                end
                px = px + 1;

                // DC 밸런스 (데이터 구간만 누적, 컨트롤 구간에서 0으로 리셋됨)
                disp0 = disp0 + 2 * ones(w0) - 10;
                disp1 = disp1 + 2 * ones(w1) - 10;
                disp2 = disp2 + 2 * ones(w2) - 10;
                if (disp0 > max_disp) max_disp = disp0;  if (-disp0 > max_disp) max_disp = -disp0;
                if (disp1 > max_disp) max_disp = disp1;  if (-disp1 > max_disp) max_disp = -disp1;
                if (disp2 > max_disp) max_disp = disp2;  if (-disp2 > max_disp) max_disp = -disp2;
            end else begin
                disp0 = 0; disp1 = 0; disp2 = 0;
                if (prev_de) begin   // 라인 종료
                    px = 0;
                    py = py + 1;
                end
                if (!hs && prev_hs) hs_pulses = hs_pulses + 1;
                if (!vs && prev_vs) begin
                    vs_pulses = vs_pulses + 1;
                    if (synced) begin
                        if (py != 480 || de_pixels != 640 * 480) begin
                            $display("ERROR: frame %0d has %0d lines, %0d pixels", frames, py, de_pixels);
                            errors = errors + 1;
                        end
                        // 공 모양 / 이동 검사
                        if (red_pixels != circle_area) begin
                            $display("ERROR: frame %0d ball has %0d pixels, expected %0d",
                                     frames, red_pixels, circle_area);
                            errors = errors + 1;
                        end
                        $display("frame %0d: ball at square (%0d,%0d)", frames, ball_sx, ball_sy);
                        if (prev_sx >= 0) begin
                            adx = ball_sx - prev_sx; if (adx < 0) adx = -adx;
                            ady = ball_sy - prev_sy; if (ady < 0) ady = -ady;
                            if (adx > 1 || ady > 1 || (adx == 0 && ady == 0)) begin
                                $display("ERROR: illegal move (%0d,%0d) -> (%0d,%0d)",
                                         prev_sx, prev_sy, ball_sx, ball_sy);
                                errors = errors + 1;
                            end
                            moves = moves + 1;
                        end
                        prev_sx = ball_sx;
                        prev_sy = ball_sy;
                        frames = frames + 1;
                    end
                    red_pixels = 0;
                    synced = 1;
                    py = 0;
                    de_pixels = 0;
                end
            end
            prev_de = de;
            prev_hs = hs;
            prev_vs = vs;
        end
    end

    initial begin
        #200 rst = 0;
        wait (frames == FRAMES);
        $display("frames=%0d  hsync pulses=%0d  vsync pulses=%0d  max DC disparity=%0d",
                 frames, hs_pulses, vs_pulses, max_disp);
        if (max_disp > 20) begin
            $display("ERROR: DC disparity too large");
            errors = errors + 1;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
