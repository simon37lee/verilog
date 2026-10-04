// ---------------------------------------------------------------------------
// hist_display : 히스토그램 두 개를 로그 스케일 막대그래프로 그린다 (640x480, clk_pix 25 MHz)
//
//   위 (y  30~229) : 측정 회로 A (CHAIN A)    아래 (y 266~465) : 측정 회로 B (CHAIN B)
//   보통은 A = ASYNC (링 오실레이터, 주황), B = SYNC (대조군, 하늘색).
//   swap = 1 이면 입력이 바뀌므로 라벨과 색도 바꾼다 (색/라벨 = 신호, 위치 = 회로).
//   x = 64 + 2 * bin (bin 0~255). 오른쪽일수록 샘플링 FF 의 출력이 늦게 바뀐 것.
//   y = log2(개수) : 칸당 1 -> 6 px, 2 배마다 6 px (최대 2^32 -> 약 197 px)
//   가로 점선 = 1, 16, 256, ... (16 배 간격). 로그 스케일이므로 지수 분포는 직선으로 보인다.
//   각 그래프 오른쪽 위에 꼬리에서 계산한 tau 를 표시 (tau_engine, 수직 귀선 동안 계산).
//     WAIT = 데이터 쌓는 중, EDGE = 봉우리가 측정 범위(0~255 칸) 밖
//   zoom = 1 이면 봉우리 근처 64 칸을 칸당 8 px 로 확대 (세로선 4 칸 간격).
//
//   파이프라인 (tri_display 와 같은 구조, sync 신호도 3 클럭 지연):
//     T0 video_timing -> T1 히스토그램 주소/영역/라벨 -> T2 데이터 도착 -> T3 RGB
// ---------------------------------------------------------------------------
module hist_display #(
    parameter TAP_X10_A = 250,            // 탭 지연 (0.1 ps), tau 의 ps 환산용
    parameter TAP_X10_B = 250,
    parameter TAIL_SHIFT = 16
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        swap,              // 비동기 입력, 여기서 동기화
    input  wire        zoom,              // 비동기 입력, 여기서 동기화
    output reg  [7:0]  hist_addr,         // 두 히스토그램 같은 주소
    input  wire [31:0] hist_a,
    input  wire [31:0] hist_b,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg         de,
    output reg         hsync,
    output reg         vsync
);
    localparam PX0    = 64;               // 그래프 왼쪽 x
    localparam PW     = 512;              // 256 bin x 2 px
    localparam A_TOP  = 30,  A_BASE = 229;
    localparam B_TOP  = 266, B_BASE = 465;
    localparam A_LBL  = 8,   B_LBL  = 244, D_LBL = 466;

    wire [11:0] x, y;
    wire        de0, hs0, vs0;
    video_timing u_timing (.clk(clk), .rst(rst), .x(x), .y(y), .de(de0), .hsync(hs0), .vsync(vs0));

    // ---- tau 계산 (수직 귀선 동안 히스토그램 읽기 포트 사용) ------------------
    wire        eng_active;
    wire [1:0]  st_a, st_b;
    wire [7:0]  eng_addr, peak_a, peak_b;
    wire [15:0] tau_a, tau_b;
    tau_engine #(.TAP_X10_A(TAP_X10_A), .TAP_X10_B(TAP_X10_B), .TAIL_SHIFT(TAIL_SHIFT)) u_tau (
        .clk(clk), .rst(rst), .start(x == 0 && y == 480),
        .active(eng_active), .addr(eng_addr), .hist_a(hist_a), .hist_b(hist_b),
        .status_a(st_a), .status_b(st_b), .peak_a(peak_a), .peak_b(peak_b), .bcd_a(tau_a), .bcd_b(tau_b)
    );

    // ---- 라벨 ---------------------------------------------------------------
    //   id 0/1: 신호 이름, 2/3: 회로 A/B 의 tau, 그 밖: "DELAY ->"
    function [7:0] digit;                 // BCD 한 자리 -> ASCII (앞자리 0 은 공백)
        input [3:0] d;
        input       blank;
        digit = blank ? " " : 8'h30 + d;
    endfunction

    function [8*16-1:0] tau_str;          // "TAU A 123.4 PS  "
        input [7:0]  name;
        input [1:0]  st;
        input [15:0] v;
        begin
            if (st == 2'd2)
                tau_str = {"TAU ", name, "  EDGE     "};
            else if (st != 2'd0)
                tau_str = {"TAU ", name, "  WAIT     "};
            else
                tau_str = {"TAU ", name, " ",
                           digit(v[15:12], v[15:12] == 0),
                           digit(v[11:8],  v[15:8] == 0),
                           digit(v[7:4], 1'b0), ".", digit(v[3:0], 1'b0), " PS  "};
        end
    endfunction

    wire [8*16-1:0] str_tau_a = tau_str("A", st_a, tau_a);
    wire [8*16-1:0] str_tau_b = tau_str("B", st_b, tau_b);

    function [7:0] label_char;            // 라벨 번호, 글자 위치 -> ASCII
        input [2:0]      id;
        input [4:0]      idx;
        input [8*16-1:0] ta, tb;
        input            zm;
        reg [8*16-1:0] s;
        begin
            case (id)
                3'd0:    s = "ASYNC RING OSC  ";
                3'd1:    s = "SYNC CONTROL    ";
                3'd2:    s = ta;
                3'd3:    s = tb;
                default: s = zm ? "ZOOM 8  DELAY ->" : "        DELAY ->";
            endcase
            label_char = (idx < 16) ? s[(15 - idx) * 8 +: 8] : " ";
        end
    endfunction

    function [4:0] font5x7;               // 글자의 한 줄 (bit4 = 왼쪽)
        input [7:0] ch;
        input [2:0] row;
        reg [34:0] gl;
        begin
            case (ch)
                "A": gl = 35'b01110_10001_10001_11111_10001_10001_10001;
                "B": gl = 35'b11110_10001_10001_11110_10001_10001_11110;
                "P": gl = 35'b11110_10001_10001_11110_10000_10000_10000;
                "U": gl = 35'b10001_10001_10001_10001_10001_10001_01110;
                "W": gl = 35'b10001_10001_10001_10101_10101_10101_01010;
                "M": gl = 35'b10001_11011_10101_10101_10001_10001_10001;
                "Z": gl = 35'b11111_00001_00010_00100_01000_10000_11111;
                "0": gl = 35'b01110_10001_10011_10101_11001_10001_01110;
                "1": gl = 35'b00100_01100_00100_00100_00100_00100_01110;
                "2": gl = 35'b01110_10001_00001_00010_00100_01000_11111;
                "3": gl = 35'b11110_00001_00001_01110_00001_00001_11110;
                "4": gl = 35'b00010_00110_01010_10010_11111_00010_00010;
                "5": gl = 35'b11111_10000_11110_00001_00001_10001_01110;
                "6": gl = 35'b00110_01000_10000_11110_10001_10001_01110;
                "7": gl = 35'b11111_00001_00010_00100_01000_01000_01000;
                "8": gl = 35'b01110_10001_10001_01110_10001_10001_01110;
                "9": gl = 35'b01110_10001_10001_01111_00001_00010_01100;
                ".": gl = 35'b00000_00000_00000_00000_00000_01100_01100;
                "C": gl = 35'b01110_10001_10000_10000_10000_10001_01110;
                "D": gl = 35'b11110_10001_10001_10001_10001_10001_11110;
                "E": gl = 35'b11111_10000_10000_11110_10000_10000_11111;
                "G": gl = 35'b01110_10001_10000_10111_10001_10001_01111;
                "I": gl = 35'b01110_00100_00100_00100_00100_00100_01110;
                "L": gl = 35'b10000_10000_10000_10000_10000_10000_11111;
                "N": gl = 35'b10001_11001_10101_10011_10001_10001_10001;
                "O": gl = 35'b01110_10001_10001_10001_10001_10001_01110;
                "R": gl = 35'b11110_10001_10001_11110_10100_10010_10001;
                "S": gl = 35'b01111_10000_10000_01110_00001_00001_11110;
                "T": gl = 35'b11111_00100_00100_00100_00100_00100_00100;
                "Y": gl = 35'b10001_10001_01010_00100_00100_00100_00100;
                "-": gl = 35'b00000_00000_00000_11111_00000_00000_00000;
                ">": gl = 35'b10000_01000_00100_00010_00100_01000_10000;
                default: gl = 35'b0;
            endcase
            font5x7 = gl[(6 - row) * 5 +: 5];
        end
    endfunction

    // ---- 개수 -> 막대 높이 (로그 스케일) ------------------------------------
    //   hl = (최상위 1 의 위치 + 1) * 8 + 그 아래 3 비트,  높이 = hl * 3/4
    function [8:0] log_height;
        input [31:0] c;
        integer i;
        reg [5:0]  msb;
        reg [31:0] sh;
        reg [8:0]  hl;
        begin
            msb = 0;
            for (i = 0; i < 32; i = i + 1) if (c[i]) msb = i;
            sh = c << (31 - msb);
            hl = (c == 0) ? 9'd0 : {msb + 6'd1, 3'b000} + sh[30:28];
            log_height = hl - (hl >> 2);
        end
    endfunction

    function is_grid;                     // 16 배 간격 가로선 (개수 1, 16, 256, ...)
        input [8:0] row;
        integer k;
        reg [8:0] hl;
        begin
            is_grid = 1'b0;
            for (k = 0; k < 8; k = k + 1) begin
                hl = (4 * k + 1) * 8;
                if (row == hl - (hl >> 2)) is_grid = 1'b1;
            end
        end
    endfunction

    // ---- T1: 영역 + 주소 + 라벨 ---------------------------------------------
    wire in_x   = (x >= PX0) && (x < PX0 + PW);
    wire in_a   = in_x && (y >= A_TOP) && (y <= A_BASE);
    wire in_b   = in_x && (y >= B_TOP) && (y <= B_BASE);
    wire [11:0] row_a = A_BASE - y;
    wire [11:0] row_b = B_BASE - y;
    wire [11:0] px    = x - PX0;

    wire        in_lbl_a = (y >= A_LBL) && (y < A_LBL + 14);
    wire        in_lbl_b = (y >= B_LBL) && (y < B_LBL + 14);
    wire        in_lbl_d = (y >= D_LBL) && (y < D_LBL + 14);
    reg  [1:0]  swap_sr, zoom_sr;
    always @(posedge clk) begin
        swap_sr <= {swap_sr[0], swap};
        zoom_sr <= {zoom_sr[0], zoom};
    end
    wire        swp = swap_sr[1];
    wire        zm  = zoom_sr[1];

    // 확대 시작 칸 = 두 봉우리 중 왼쪽 것 - 8 (0 ~ 192 로 제한), 프레임마다 갱신
    wire [7:0]  pk_min = (peak_a < peak_b) ? peak_a : peak_b;
    reg  [7:0]  origin;
    always @(posedge clk)
        if (x == 0 && y == 0)
            origin <= (pk_min < 8) ? 8'd0 : (pk_min > 200) ? 8'd192 : pk_min - 8'd8;

    wire        lbl_left  = (x >= PX0) && (x < PX0 + 256);
    wire        lbl_right = (x >= PX0 + 256) && (x < PX0 + 512);
    wire [2:0]  lbl_id = in_lbl_d  ? 3'd4
                       : lbl_right ? (in_lbl_a ? 3'd2 : 3'd3)
                       :             ((in_lbl_a ^ swp) ? 3'd0 : 3'd1);
    wire [11:0] lx  = x - (lbl_right ? PX0 + 256 : PX0);
    wire [11:0] lly = y - (in_lbl_a ? A_LBL : in_lbl_b ? B_LBL : D_LBL);
    wire [7:0]  ch  = label_char(lbl_id, lx[8:4], str_tau_a, str_tau_b, zm);
    wire [4:0]  gly = font5x7(ch, lly[3:1]);
    wire        text_on = ((in_lbl_a || in_lbl_b) && (lbl_left || lbl_right) || (in_lbl_d && lbl_right))
                          && (lx[3:1] < 5) && gly[4 - lx[3:1]];

    reg       de1, hs1, vs1, a1, b1, text1, vgrid1;
    reg [8:0] row1;
    always @(posedge clk) begin
        hist_addr <= eng_active ? eng_addr : zm ? origin + px[8:3] : px[8:1];
        {de1, hs1, vs1} <= {de0, hs0, vs0};
        a1     <= in_a;
        b1     <= in_b;
        row1   <= in_a ? row_a[8:0] : row_b[8:0];
        text1  <= text_on;
        vgrid1 <= (px[4:0] == 5'd0);       // 32 px 마다 세로선 (보통 16 칸, 확대 4 칸)
    end

    // ---- T2: 히스토그램 데이터 도착 -----------------------------------------
    reg       de2, hs2, vs2, a2, b2, text2, vgrid2;
    reg [8:0] row2;
    always @(posedge clk) begin
        {de2, hs2, vs2} <= {de1, hs1, vs1};
        {a2, b2, text2, vgrid2} <= {a1, b1, text1, vgrid1};
        row2 <= row1;
    end

    // ---- T3: RGB -------------------------------------------------------------
    wire [8:0] h_a = log_height(hist_a);
    wire [8:0] h_b = log_height(hist_b);
    wire       bar = a2 ? (row2 < h_a) : (row2 < h_b);

    always @(posedge clk) begin
        {de, hsync, vsync} <= {de2, hs2, vs2};
        if (!de2)
            {r, g, b} <= 24'h000000;
        else if (text2)
            {r, g, b} <= 24'hE0E0E0;
        else if ((a2 || b2) && bar)
            {r, g, b} <= (a2 ^ swp) ? 24'hFF8020 : 24'h30C0FF;   // 비동기 = 주황, 동기 = 하늘색
        else if ((a2 || b2) && row2 == 0)
            {r, g, b} <= 24'h808080;                       // 기준선
        else if ((a2 || b2) && (is_grid(row2) || vgrid2))
            {r, g, b} <= 24'h383838;                       // 눈금
        else if (a2 || b2)
            {r, g, b} <= 24'h141414;                       // 그래프 배경
        else
            {r, g, b} <= 24'h000000;
    end
endmodule
