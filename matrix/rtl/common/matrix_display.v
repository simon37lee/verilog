// ---------------------------------------------------------------------------
// matrix_display : 글자 칸 RAM + 글꼴 ROM -> 1280x720 픽셀
//
//   화면을 16 x 24 칸 80 x 30 개로 나눈다. 칸 하나 = 셀 RAM 한 워드 (12 비트):
//     [11:6] 밝기 (0 = 빈 칸, 1~55 초록, 56~63 머리 글자처럼 흰색에 가까워짐)
//     [5:0]  글자 번호 (glyph_rom)
//   셀 주소 = 줄 * 80 + 칸
//
//   파이프라인 (video_timing 출력 기준 4 클럭 지연, de / hsync / vsync 도 같이 늦춘다):
//     1 : 줄 = y / 24 (y * 2731 >> 16, y < 750 에서 정확), 칸 안 줄 = y - 줄 * 24, 셀 주소
//     2 : 셀 RAM 읽기
//     3 : 글꼴 ROM 읽기 ({글자 번호, 칸 안 줄})
//     4 : 칸 안 x 위치의 비트 고르기 + 밝기 -> RGB
// ---------------------------------------------------------------------------
module matrix_display (
    input  wire        clk,
    input  wire        rst,
    // video_timing 출력
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de_in,
    input  wire        hs_in,
    input  wire        vs_in,
    // 셀 RAM 읽기 포트 (읽기 지연 1 클럭)
    output reg  [11:0] cell_addr,
    input  wire [11:0] cell_data,
    // 영상 출력
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg         de,
    output reg         hsync,
    output reg         vsync
);
    localparam COLS = 80;

    // 밝기 -> RGB (C++ 검사기 vmon_matrix.cpp 의 palette() 와 같아야 한다)
    function [23:0] palette;
        input [5:0] i;
        reg   [7:0] w;
        begin
            w = (i >= 6'd56) ? {i[2:0], 5'b11111} : {2'b00, i};
            palette = {(i >= 6'd56) ? w : 8'd0, {i, 2'b11}, w};
        end
    endfunction

    // ---- 1 : 셀 주소 ------------------------------------------------------------
    wire [23:0] row_mul = y * 12'd2731;
    wire [6:0]  row     = row_mul[22:16];
    wire [11:0] sub     = y - {row, 4'b0} - {row, 3'b0};
    wire [6:0]  col     = x[10:4];

    reg  [4:0]  s1_sub;
    reg  [3:0]  s1_xb;
    reg         s1_de, s1_hs, s1_vs;
    always @(posedge clk) begin
        cell_addr <= {row, 6'b0} + {row, 4'b0} + col;     // row * 80 + col
        s1_sub    <= sub[4:0];
        s1_xb     <= x[3:0];
        s1_de     <= de_in;
        s1_hs     <= hs_in;
        s1_vs     <= vs_in;
    end

    // ---- 2 : 셀 RAM 읽기 (cell_data) ---------------------------------------------
    reg  [4:0]  s2_sub;
    reg  [3:0]  s2_xb;
    reg         s2_de, s2_hs, s2_vs;
    always @(posedge clk) begin
        s2_sub <= s1_sub;
        s2_xb  <= s1_xb;
        s2_de  <= s1_de;
        s2_hs  <= s1_hs;
        s2_vs  <= s1_vs;
    end

    // ---- 3 : 글꼴 ROM 읽기 --------------------------------------------------------
    wire [15:0] bits;
    glyph_rom u_rom (.clk(clk), .addr({cell_data[5:0], s2_sub}), .bits(bits));

    reg  [5:0]  s3_int;
    reg  [3:0]  s3_xb;
    reg         s3_de, s3_hs, s3_vs;
    always @(posedge clk) begin
        s3_int <= cell_data[11:6];
        s3_xb  <= s2_xb;
        s3_de  <= s2_de;
        s3_hs  <= s2_hs;
        s3_vs  <= s2_vs;
    end

    // ---- 4 : 픽셀 -> RGB ---------------------------------------------------------
    wire        on  = bits[4'd15 - s3_xb] && (s3_int != 6'd0);
    wire [23:0] rgb = palette(s3_int);
    always @(posedge clk) begin
        if (rst) begin
            {r, g, b} <= 24'd0;
            de        <= 1'b0;
            hsync     <= 1'b0;
            vsync     <= 1'b0;
        end else begin
            {r, g, b} <= (on && s3_de) ? rgb : 24'd0;
            de        <= s3_de;
            hsync     <= s3_hs;
            vsync     <= s3_vs;
        end
    end
endmodule
