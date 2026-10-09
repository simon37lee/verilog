// ---------------------------------------------------------------------------
// mandel_display (v5) : 줄 버퍼 -> 800x600 화면 (clk_pix 40 MHz 도메인)
//
//   800x600 @ 60 Hz (VESA, sync 양극성) 에 DDR2 프레임버퍼 (rd_buf 번 버퍼) 를 1:1 로 표시한다.
//   DDR2 는 fb_reader 가 줄 단위로 읽어 오므로, 줄 y 를 내보내기 시작할 때 (x = 0) 줄 y+1 을 요청한다
//   (줄 0 은 마지막 블랭크 줄에서). 줄 y 는 줄 버퍼 반쪽 y mod 2 에 있다.
//   그 밖에는 공통 mandel_display 와 같고,
//   왼쪽 위에 두 줄을 겹쳐 그린다:
//       "  77.64 ms "   마지막 프레임 렌더 시간
//       "v1     13 fps" 엔진 버전, 최근 60 화면 프레임 (약 1 초) 동안 완성된 렌더 프레임 수
//
//   파이프라인 (video_timing 출력 = 단계 0)
//     1: 줄 버퍼 주소 {y mod 2, x/4}, 바이트 번호 x mod 4 | 글자 칸 번호, 글자 안 좌표
//     2: 줄 버퍼 워드 -> 바이트 하나 (팔레트 번호)        | 글리프 한 줄 (5 비트)
//     3: 팔레트 RGB (ROM)                             | 글자 픽셀 비트, 배경 상자
//     4: 출력 레지스터 (글자 = 흰색, 상자 = 1/4 밝기)
//   de / hsync / vsync 도 4 클럭 늦춰서 맞춘다.
// ---------------------------------------------------------------------------
module mandel_display #(
    parameter VERSION = 5           // 화면에 표시할 엔진 버전 (1~99)
) (
    input  wire          clk,
    input  wire          rst,
    // 줄 버퍼 (fb_reader)
    input  wire          rd_buf,        // 보여 줄 버퍼
    output reg           ln_req,        // 줄 ln_line 을 DDR2 에서 읽어 반쪽 ln_line mod 2 에 채워 달라
    output reg  [9:0]    ln_line,
    output reg           ln_buf,
    output reg  [8:0]    lb_addr,
    input  wire [31:0]   lb_data,
    // 표시할 렌더 시간 (10 us 단위 BCD 6 자리), 렌더 프레임 완성 펄스 (fps 계산)
    input  wire [23:0]   perf_bcd,
    input  wire          render_done,
    // 디버그 셋째 줄: 숫자 6 개 (각 4 비트, 0~9 만 표시). mandel_system 참고
    input  wire [23:0]   dbg,
    output wire          vs_start,      // vsync 시작 (1 클럭 펄스, 버퍼 교체 시점)
    // 영상 출력
    output reg  [7:0]    r, g, b,
    output reg           de, hsync, vsync
);
    // ---- 0: 타이밍 ---------------------------------------------------------
    wire [11:0] x, y;
    wire        de0, hs0, vs0;
    localparam FB_W = 800, FB_H = 600, V_TOTAL = 628;
    video_timing #(
        .H_ACTIVE(800), .H_FP(40), .H_SYNC(128), .H_BP(88),
        .V_ACTIVE(600), .V_FP(1),  .V_SYNC(4),   .V_BP(23),
        .HS_POL(1), .VS_POL(1)
    ) u_tim (.clk(clk), .rst(rst), .x(x), .y(y), .de(de0), .hsync(hs0), .vsync(vs0));

    // de_d[i] = 단계 i+1 에 정렬된 값
    reg [2:0] de_d, hs_d, vs_d;
    always @(posedge clk) begin
        de_d <= {de_d[1:0], de0};
        hs_d <= {hs_d[1:0], hs0};
        vs_d <= {vs_d[1:0], vs0};
    end
    assign vs_start = !vs_d[0] && vs0;      // vsync 는 active-high (800x600)

    // ---- 다음 줄 요청 ---------------------------------------------------------
    always @(posedge clk) begin
        ln_req <= 1'b0;
        if (x == 0 && y < FB_H - 1) begin
            ln_req  <= 1'b1;
            ln_line <= y[9:0] + 1'b1;
            ln_buf  <= rd_buf;
        end else if (x == 0 && y == V_TOTAL - 1) begin
            ln_req  <= 1'b1;
            ln_line <= 0;
            ln_buf  <= rd_buf;
        end
    end

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
    localparam BX0 = TX - 6, BY0 = TY - 6, BX1 = TX + NCHAR * 16 + 4, BY1 = TY + 2 * LH + 16 + 4;

    // 버전 번호 (10 진 두 자리)
    localparam [3:0] VER_HI = VERSION / 10, VER_LO = VERSION % 10;

    // 문자 코드: 0~9 숫자, 10 '.', 11 'm', 12 's', 13 'f', 14 'p', 15 공백, 16 'v'
    //   앞자리 0 은 공백으로 (자릿수마다 그 앞이 모두 0 인지 본다)
    function [4:0] char_at;
        input [1:0]  line;
        input [3:0]  col;
        input [23:0] v;         // 렌더 시간 BCD
        input [11:0] f;         // fps BCD
        input [23:0] d;         // 디버그 숫자
        begin
            char_at = 5'd15;
            if (line == 2'd2) begin
                case (col)
                    4'd0: char_at = {1'b0, d[23:20]};
                    4'd2: char_at = {1'b0, d[19:16]};
                    4'd4: char_at = {1'b0, d[15:12]};
                    4'd5: char_at = {1'b0, d[11:8]};
                    4'd6: char_at = {1'b0, d[7:4]};
                    4'd8: char_at = {1'b0, d[3:0]};
                    default: ;
                endcase
            end else if (line == 2'd0) begin
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

    // 디버그 값은 clk_core 쪽에서 온다. 천천히 바뀌는 상태라 2FF 만 (여러 비트가 한 순간 섞여도 다음 줄에 바로잡힘)
    reg [23:0] dbg_m, dbg_s;
    always @(posedge clk) begin
        dbg_m <= dbg;
        dbg_s <= dbg_m;
    end

    // ---- 1 ------------------------------------------------------------------
    wire [1:0]  line = (y >= TY + 2 * LH) ? 2'd2 : (y >= TY + LH) ? 2'd1 : 2'd0;
    wire [11:0] tx = x - TX;
    wire [11:0] ty = y - (line == 2'd2 ? TY + 2 * LH : line == 2'd1 ? TY + LH : TY);
    reg  [1:0]  lane1;
    reg  [3:0]  col1;
    reg  [2:0]  gx1, gy1;
    reg  [1:0]  line1;
    reg         in_text1, in_box1;

    always @(posedge clk) begin
        lb_addr  <= {y[0], x[9:2]};
        lane1    <= x[1:0];
        col1     <= tx[7:4];
        gx1      <= tx[3:1];
        gy1      <= ty[3:1];
        line1    <= line;
        in_text1 <= (x >= TX) && (x < TX + NCHAR * 16) &&
                    (((y >= TY) && (y < TY + 16)) || ((y >= TY + LH) && (y < TY + LH + 16)) ||
                     ((y >= TY + 2 * LH) && (y < TY + 2 * LH + 16)));
        in_box1  <= (x >= BX0) && (x < BX1) && (y >= BY0) && (y < BY1);
    end

    // ---- 2 ------------------------------------------------------------------
    reg [1:0] lane2;
    always @(posedge clk) lane2 <= lane1;

    reg [7:0] idx2;
    always @(*) begin
        case (lane2)
            2'd0: idx2 = lb_data[7:0];
            2'd1: idx2 = lb_data[15:8];
            2'd2: idx2 = lb_data[23:16];
            default: idx2 = lb_data[31:24];
        endcase
    end

    reg [4:0] row2;
    reg [2:0] gx2;
    reg       in_text2, in_box2;
    always @(posedge clk) begin
        row2     <= glyph(char_at(line1, col1, perf_bcd, fps_bcd, dbg_s), gy1);
        gx2      <= gx1;
        in_text2 <= in_text1;
        in_box2  <= in_box1;
    end

    // ---- 3 ------------------------------------------------------------------
    wire [23:0] pal3;
    palette_rom u_pal (.clk(clk), .idx(idx2), .rgb(pal3));

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
            hsync <= 1'b0;          // sync 양극성 -> 평소 0
            vsync <= 1'b0;
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
