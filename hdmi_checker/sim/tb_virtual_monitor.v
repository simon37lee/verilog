// ---------------------------------------------------------------------------
// tb_virtual_monitor : 가상 모니터
//
//   hdmi_core + tmds_serializer 가 내보내는 직렬 TMDS 신호를 실제 모니터처럼
//   받아서 (역직렬화 -> TMDS 디코딩 -> sync 로 화면 위치 복원)
//   프레임마다 PPM 이미지 파일로 저장한다.
//
//   해상도는 DE 구간 길이와 라인 수로 자동 측정한다.
//   +FRAMES=<n>  : 저장할 프레임 수 (기본 1)
//   +OUT=<prefix>: 출력 파일 이름 앞부분 (기본 "frame") -> frame_0.ppm ...
//
//   실제 하드웨어는 0.1 s(약 6프레임)마다 공이 움직이지만, 시뮬레이션 시간을
//   줄이기 위해 여기서는 MOVE_CYCLES 를 1프레임으로 줄여 프레임마다 움직이게 한다.
//   (뷰어에서 0.1 s 간격으로 재생하면 실제와 같은 속도로 보인다)
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_virtual_monitor;
    localparam MAX_W = 1920;
    localparam MAX_H = 1080;
    parameter  MOVE_CYCLES = 800 * 525;   // 1프레임 (-P 로 바꿀 수 있음)

    reg clk_x10 = 0;
    reg clk_pix = 0;
    reg rst     = 1;

    always #2 clk_x10 = ~clk_x10;
    initial forever #20 clk_pix = ~clk_pix;

    // ---- 검증 대상 (송신기) -------------------------------------------------
    wire [9:0] t0, t1, t2;
    wire       s0, s1, s2, sclk;

    hdmi_core #(.MOVE_CYCLES(MOVE_CYCLES)) dut (
        .clk_pix(clk_pix), .rst(rst), .tmds_ch0(t0), .tmds_ch1(t1), .tmds_ch2(t2)
    );

    tmds_serializer ser (
        .clk_x10(clk_x10), .rst(rst), .ch0(t0), .ch1(t1), .ch2(t2),
        .s_ch0(s0), .s_ch1(s1), .s_ch2(s2), .s_clk(sclk)
    );

    // ---- 수신기: 역직렬화 (클럭 채널 0000011111 위상으로 워드 경계 검출) ----
    reg [9:0] w0, w1, w2, wc;
    always @(posedge clk_x10) begin
        w0 <= {s0, w0[9:1]};
        w1 <= {s1, w1[9:1]};
        w2 <= {s2, w2[9:1]};
        wc <= {sclk, wc[9:1]};
    end

    // ---- 수신기: TMDS 디코더 -> {is_ctrl, -, data(or c1c0)} -----------------
    function [9:0] decode;
        input [9:0] q;
        reg   [7:0] dd;
        integer k;
        begin
            case (q)
                10'b1101010100: decode = {2'b10, 8'h00};
                10'b0010101011: decode = {2'b10, 8'h01};
                10'b0101010100: decode = {2'b10, 8'h02};
                10'b1010101011: decode = {2'b10, 8'h03};
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

    // ---- 프레임 버퍼 & 파일 저장 -------------------------------------------
    reg [23:0] fb [0:MAX_W*MAX_H-1];

    integer n_frames, saved = 0;
    reg [8*64-1:0] out_prefix;
    reg [8*80-1:0] fname;

    integer px = 0, py = 0, width = 0;
    reg     prev_de = 0, prev_vs = 1, synced = 0;
    reg [9:0] d0, d1, d2;
    reg       de, vs;

    task save_frame;
        integer fd, i, j;
        reg [23:0] c;
        begin
            $sformat(fname, "%0s_%0d.ppm", out_prefix, saved);
            fd = $fopen(fname, "w");
            $fwrite(fd, "P3\n%0d %0d\n255\n", width, py);
            for (j = 0; j < py; j = j + 1)
                for (i = 0; i < width; i = i + 1) begin
                    c = fb[j * MAX_W + i];
                    $fwrite(fd, "%0d %0d %0d\n", c[23:16], c[15:8], c[7:0]);
                end
            $fclose(fd);
            $display("[virtual monitor] %0s  (%0dx%0d)", fname, width, py);
            saved = saved + 1;
        end
    endtask

    always @(posedge clk_x10) begin
        if (!rst && wc == 10'b0000011111) begin
            d0 = decode(w0);   // Blue  + sync
            d1 = decode(w1);   // Green
            d2 = decode(w2);   // Red
            de = !d0[9];
            vs = d0[1];

            if (de) begin
                if (synced && px < MAX_W && py < MAX_H)
                    fb[py * MAX_W + px] = {d2[7:0], d1[7:0], d0[7:0]};
                px = px + 1;
            end else begin
                if (prev_de) begin          // 라인 끝
                    width = px;
                    px = 0;
                    py = py + 1;
                end
                if (!vs && prev_vs) begin   // vsync 시작 = 프레임 끝 (active-low)
                    if (synced && py > 0)
                        save_frame;
                    synced = 1;
                    py = 0;
                end
            end
            prev_de = de;
            prev_vs = vs;
        end
    end

    initial begin
        if (!$value$plusargs("FRAMES=%d", n_frames)) n_frames = 1;
        if (!$value$plusargs("OUT=%s", out_prefix))  out_prefix = "frame";
        #200 rst = 0;
        wait (saved == n_frames);
        $finish;
    end
endmodule
