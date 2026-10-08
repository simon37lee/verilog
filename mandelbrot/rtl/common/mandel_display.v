// ---------------------------------------------------------------------------
// mandel_display : 프레임버퍼 -> 화면 (clk_pix 도메인)
//
//   640x480 화면에 320x240 프레임버퍼 (rd_buf 번 버퍼) 를 2 배 확대해서 표시하고,
//   왼쪽 위에 두 줄을 겹쳐 그린다:
//       "  77.64 ms "   마지막 프레임 렌더 시간
//       "v1     13 fps" 엔진 버전, 최근 60 화면 프레임 (약 1 초) 동안 완성된 렌더 프레임 수
//
//   파이프라인 (video_timing 출력 = 단계 0)
//     1: 프레임버퍼 주소 버퍼*76800 + (y/2)*320 + x/2 | 글자 칸 번호, 글자 안 좌표
//     2: 프레임버퍼 데이터 (Block RAM)                | 글리프 한 줄 (5 비트)
//     3: 팔레트 RGB (ROM)                             | 글자 픽셀 비트, 배경 상자
//     4: 출력 레지스터 (글자 = 흰색, 상자 = 1/4 밝기)
//   de / hsync / vsync 도 4 클럭 늦춰서 맞춘다.
// ---------------------------------------------------------------------------
module mandel_display #(
    parameter AW      = 18,
    parameter VERSION = 1           // 화면에 표시할 엔진 버전 (1~99)
) (
    input  wire          clk,
    input  wire          rst,
    // 프레임버퍼 읽기 포트
    input  wire          rd_buf,        // 보여 줄 버퍼
    output reg  [AW-1:0] fb_addr,
    input  wire [7:0]    fb_data,
    // 표시할 렌더 시간 (10 us 단위 BCD 6 자리), 렌더 프레임 완성 펄스 (fps 계산)
    input  wire [23:0]   perf_bcd,
    input  wire          render_done,
    output wire          vs_start,      // vsync 시작 (1 클럭 펄스, 버퍼 교체 시점)
    // 영상 출력
    output reg  [7:0]    r, g, b,
    output reg           de, hsync, vsync
);
    // ---- 0: 타이밍 ---------------------------------------------------------
    wire [11:0] x, y;
    wire        de0, hs0, vs0;
    video_timing u_tim (.clk(clk), .rst(rst), .x(x), .y(y), .de(de0), .hsync(hs0), .vsync(vs0));

    // de_d[i] = 단계 i+1 에 정렬된 값
    reg [2:0] de_d, hs_d, vs_d;
    always @(posedge clk) begin
        de_d <= {de_d[1:0], de0};
        hs_d <= {hs_d[1:0], hs0};
        vs_d <= {vs_d[1:0], vs0};
    end
    assign vs_start = vs_d[0] && !vs0;      // vsync 는 active-low

    // ---- fps: 화면 60 프레임 동안 render_done 개수 (BCD 3 자리) ------------------
    reg [5:0]  vs_cnt;
    reg [11:0] fps_cnt, fps_bcd;

    function [11:0] bcd3_inc;
        input [11:0] v;
        begin
            if (v == 12'h999)           bcd3_inc = v;
            else if (v[7:0] == 8'h99)   bcd3_inc = {v[11:8] + 4'd1, 8'h00};
            else if (v[3:0] == 4'h9)    bcd3_inc = {v[11:8], v[7:4] + 4'd1, 4'h0};
            else                        bcd3_inc = v + 12'd1;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            vs_cnt  <= 0;
            fps_cnt <= 0;
            fps_bcd <= 0;
        end else if (vs_start && vs_cnt == 6'd59) begin
            vs_cnt  <= 0;
            fps_bcd <= render_done ? bcd3_inc(fps_cnt) : fps_cnt;
            fps_cnt <= 0;
        end else begin
            if (vs_start)    vs_cnt  <= vs_cnt + 1'b1;
            if (render_done) fps_cnt <= bcd3_inc(fps_cnt);
        end
    end

    // ---- 글자 위치: 칸 16x16 (5x7 글리프를 2 배), 왼쪽 위 (TX, TY) 부터 NCHAR 칸, 줄 간격 LH ----
    localparam TX = 16, TY = 16, NCHAR = 11, LH = 20;
    localparam BX0 = TX - 6, BY0 = TY - 6, BX1 = TX + NCHAR * 16 + 4, BY1 = TY + LH + 16 + 4;

    // 버전 번호 (10 진 두 자리)
    localparam [3:0] VER_HI = VERSION / 10, VER_LO = VERSION % 10;

    // 문자 코드: 0~9 숫자, 10 '.', 11 'm', 12 's', 13 'f', 14 'p', 15 공백, 16 'v'
    //   앞자리 0 은 공백으로 (자릿수마다 그 앞이 모두 0 인지 본다)
    function [4:0] char_at;
        input        line;
        input [3:0]  col;
        input [23:0] v;         // 렌더 시간 BCD
        input [11:0] f;         // fps BCD
        begin
            char_at = 5'd15;
            if (!line) begin
                case (col)
                    4'd0: if (v[23:20] != 0)  char_at = {1'b0, v[23:20]};
                    4'd1: if (v[23:16] != 0)  char_at = {1'b0, v[19:16]};
                    4'd2: if (v[23:12] != 0)  char_at = {1'b0, v[15:12]};
                    4'd3: char_at = {1'b0, v[11:8]};
                    4'd4: char_at = 5'd10;
                    4'd5: char_at = {1'b0, v[7:4]};
                    4'd6: char_at = {1'b0, v[3:0]};
                    4'd8: char_at = 5'd11;
                    4'd9: char_at = 5'd12;
                    default: ;
                endcase
            end else begin
                case (col)
                    4'd0:  char_at = 5'd16;
                    4'd1:  char_at = (VER_HI != 0) ? {1'b0, VER_HI} : {1'b0, VER_LO};
                    4'd2:  if (VER_HI != 0) char_at = {1'b0, VER_LO};
                    4'd4:  if (f[11:8] != 0) char_at = {1'b0, f[11:8]};
                    4'd5:  if (f[11:4] != 0) char_at = {1'b0, f[7:4]};
                    4'd6:  char_at = {1'b0, f[3:0]};
                    4'd8:  char_at = 5'd13;
                    4'd9:  char_at = 5'd14;
                    4'd10: char_at = 5'd12;
                    default: ;
                endcase
            end
        end
    endfunction

    // 5x7 글리프 한 줄 (MSB 가 왼쪽)
    function [4:0] glyph;
        input [4:0] c;
        input [2:0] row;
        reg [34:0] gl;
        begin
            case (c)
                5'd0:  gl = {5'b01110, 5'b10001, 5'b10011, 5'b10101, 5'b11001, 5'b10001, 5'b01110};
                5'd1:  gl = {5'b00100, 5'b01100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b01110};
                5'd2:  gl = {5'b01110, 5'b10001, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b11111};
                5'd3:  gl = {5'b11111, 5'b00010, 5'b00100, 5'b00010, 5'b00001, 5'b10001, 5'b01110};
                5'd4:  gl = {5'b00010, 5'b00110, 5'b01010, 5'b10010, 5'b11111, 5'b00010, 5'b00010};
                5'd5:  gl = {5'b11111, 5'b10000, 5'b11110, 5'b00001, 5'b00001, 5'b10001, 5'b01110};
                5'd6:  gl = {5'b00110, 5'b01000, 5'b10000, 5'b11110, 5'b10001, 5'b10001, 5'b01110};
                5'd7:  gl = {5'b11111, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b01000, 5'b01000};
                5'd8:  gl = {5'b01110, 5'b10001, 5'b10001, 5'b01110, 5'b10001, 5'b10001, 5'b01110};
                5'd9:  gl = {5'b01110, 5'b10001, 5'b10001, 5'b01111, 5'b00001, 5'b00010, 5'b01100};
                5'd10: gl = {5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b01100, 5'b01100};
                5'd11: gl = {5'b00000, 5'b00000, 5'b11010, 5'b10101, 5'b10101, 5'b10001, 5'b10001};
                5'd12: gl = {5'b00000, 5'b00000, 5'b01110, 5'b10000, 5'b01110, 5'b00001, 5'b11110};
                5'd13: gl = {5'b00110, 5'b01001, 5'b01000, 5'b11100, 5'b01000, 5'b01000, 5'b01000};
                5'd14: gl = {5'b00000, 5'b00000, 5'b11110, 5'b10001, 5'b11110, 5'b10000, 5'b10000};
                5'd16: gl = {5'b00000, 5'b00000, 5'b10001, 5'b10001, 5'b10001, 5'b01010, 5'b00100};
                default: gl = 35'd0;
            endcase
            glyph = (row < 3'd7) ? gl[34 - 5*row -: 5] : 5'd0;
        end
    endfunction

    // ---- 1 ------------------------------------------------------------------
    wire        line = (y >= TY + LH);
    wire [11:0] tx = x - TX;
    wire [11:0] ty = y - (line ? TY + LH : TY);
    wire [AW-1:0] base = rd_buf ? 320 * 240 : 0;
    reg  [3:0]  col1;
    reg  [2:0]  gx1, gy1;
    reg         line1, in_text1, in_box1;

    always @(posedge clk) begin
        // 버퍼*76800 + (y/2)*320 + x/2 = base + (y/2)*256 + (y/2)*64 + x/2
        fb_addr  <= base + {y[8:1], 8'd0} + {y[8:1], 6'd0} + x[9:1];
        col1     <= tx[7:4];
        gx1      <= tx[3:1];
        gy1      <= ty[3:1];
        line1    <= line;
        in_text1 <= (x >= TX) && (x < TX + NCHAR * 16) &&
                    (((y >= TY) && (y < TY + 16)) || ((y >= TY + LH) && (y < TY + LH + 16)));
        in_box1  <= (x >= BX0) && (x < BX1) && (y >= BY0) && (y < BY1);
    end

    // ---- 2 ------------------------------------------------------------------
    reg [4:0] row2;
    reg [2:0] gx2;
    reg       in_text2, in_box2;
    always @(posedge clk) begin
        row2     <= glyph(char_at(line1, col1, perf_bcd, fps_bcd), gy1);
        gx2      <= gx1;
        in_text2 <= in_text1;
        in_box2  <= in_box1;
    end

    // ---- 3 ------------------------------------------------------------------
    wire [23:0] pal3;
    palette_rom u_pal (.clk(clk), .idx(fb_data), .rgb(pal3));

    reg text3, in_box3;
    always @(posedge clk) begin
        text3   <= in_text2 && (gx2 < 3'd5) && row2[3'd4 - gx2];
        in_box3 <= in_box2;
    end

    // ---- 4: 출력 --------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            {r, g, b} <= 24'd0;
            de    <= 1'b0;
            hsync <= 1'b1;
            vsync <= 1'b1;
        end else begin
            if (!de_d[2])     {r, g, b} <= 24'd0;
            else if (text3)   {r, g, b} <= 24'hFFFFFF;
            else if (in_box3) {r, g, b} <= {2'b0, pal3[23:18], 2'b0, pal3[15:10], 2'b0, pal3[7:2]};
            else              {r, g, b} <= pal3;
            de    <= de_d[2];
            hsync <= hs_d[2];
            vsync <= vs_d[2];
        end
    end
endmodule
