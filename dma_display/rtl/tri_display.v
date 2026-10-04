// ---------------------------------------------------------------------------
// tri_display : 640x480 화면을 3등분해 버퍼 3개를 동시에 보여준다 (clk_pix 25 MHz)
//
//   열 0 (x   6~205) : 소스     (테두리 초록)  "SRC 33MHZ"
//   열 1 (x 220~419) : 타겟1   (테두리 주황)  "TGT1 FIFO"   async FIFO 로 받은 것
//   열 2 (x 434~633) : 타겟2   (테두리 빨강)  "TGT2 NO CDC" CDC 없이 받은 것
//   y 140~339 에 200x200 으로 표시 (버퍼를 가로/세로 STEP 픽셀마다 솎아서 읽음:
//   400x400 버퍼는 STEP=2, 200x200 버퍼는 STEP=1)
//   이미지 위(y 116~129)에 라벨 (5x7 폰트, 2배 확대)
//
//   파이프라인 (sync 신호도 같이 3클럭 지연):
//     T0 video_timing  ->  T1 RAM 주소/영역/라벨  ->  T2 RAM 데이터  ->  T3 RGB 출력
//
//   오류 누적 맵 (errmap = 1, 스크롤이 멈춘 상태에서 사용):
//     타겟2 픽셀이 타겟1 과 다르면 화면 좌표별 1비트 맵에 표시하고, 맵에 표시된 픽셀은
//     타겟2 열에 빨간 점으로 계속 보여준다. 깨진 픽셀은 다음 프레임 복사로 곧 덮여서
//     눈에 잘 안 띄므로, 한 번이라도 깨진 자리를 남겨서 CDC 없는 전송의 오류를 눈으로 본다.
//     errmap 을 켠 뒤 SETTLE 프레임 동안은 (스크롤이 멈추고 두 타겟이 같은 프레임이 될 때까지)
//     맵을 지우기만 하고, errmap = 0 이면 맵을 계속 지운다.
// ---------------------------------------------------------------------------
module tri_display #(
    parameter BUF_W  = 400,
    parameter STEP   = 2,                // 버퍼 솎음 간격 (BUF_W / IMG)
    parameter AW     = 18,
    parameter IMG    = 200,              // 화면에 보이는 크기
    parameter TOP    = 140,
    parameter LABEL_Y = 116,
    parameter BORDER = 2,
    parameter SETTLE = 8                 // errmap 을 켠 뒤 누적을 시작할 때까지 프레임 수
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          errmap,         // 오류 누적 맵 켜기 (비동기 입력, 여기서 동기화)
    // RAM port B 읽기 (세 버퍼 같은 주소)
    output reg  [AW-1:0] ram_addr,
    input  wire [7:0]    src_rdata,
    input  wire [7:0]    tgt1_rdata,
    input  wire [7:0]    tgt2_rdata,
    // 영상 출력
    output reg  [7:0]    r,
    output reg  [7:0]    g,
    output reg  [7:0]    b,
    output reg           de,
    output reg           hsync,
    output reg           vsync
);
    localparam X0 = 6, X1 = 220, X2 = 434;

    // 640x480 @ 60 Hz (25 MHz, sync 음극성)
    wire [11:0] x, y;
    wire        de0, hs0, vs0;

    video_timing u_timing (
        .clk(clk), .rst(rst), .x(x), .y(y), .de(de0), .hsync(hs0), .vsync(vs0)
    );

    // ---- 라벨 문자열과 5x7 폰트 -------------------------------------------
    function [7:0] label_char;           // 열 번호, 글자 위치 -> ASCII
        input [1:0] col;
        input [3:0] idx;
        reg [8*12-1:0] s;
        begin
            case (col)
                2'd0:    s = "SRC 33MHZ   ";
                2'd1:    s = "TGT1 FIFO   ";
                default: s = "TGT2 NO CDC ";
            endcase
            label_char = (idx < 12) ? s[(11 - idx) * 8 +: 8] : " ";
        end
    endfunction

    function [4:0] font5x7;              // 글자의 한 줄 (bit4 = 왼쪽)
        input [7:0] ch;
        input [2:0] row;
        reg [34:0] gl;
        begin
            case (ch)
                "S": gl = 35'b01111_10000_10000_01110_00001_00001_11110;
                "R": gl = 35'b11110_10001_10001_11110_10100_10010_10001;
                "C": gl = 35'b01110_10001_10000_10000_10000_10001_01110;
                "3": gl = 35'b11110_00001_00001_01110_00001_00001_11110;
                "M": gl = 35'b10001_11011_10101_10101_10001_10001_10001;
                "H": gl = 35'b10001_10001_10001_11111_10001_10001_10001;
                "Z": gl = 35'b11111_00001_00010_00100_01000_10000_11111;
                "T": gl = 35'b11111_00100_00100_00100_00100_00100_00100;
                "G": gl = 35'b01110_10001_10000_10111_10001_10001_01111;
                "1": gl = 35'b00100_01100_00100_00100_00100_00100_01110;
                "2": gl = 35'b01110_10001_00001_00010_00100_01000_11111;
                "F": gl = 35'b11111_10000_10000_11110_10000_10000_10000;
                "I": gl = 35'b01110_00100_00100_00100_00100_00100_01110;
                "O": gl = 35'b01110_10001_10001_10001_10001_10001_01110;
                "N": gl = 35'b10001_11001_10101_10011_10001_10001_10001;
                "D": gl = 35'b11110_10001_10001_10001_10001_10001_11110;
                default: gl = 35'b0;
            endcase
            font5x7 = gl[(6 - row) * 5 +: 5];
        end
    endfunction

    // ---- T1: 영역 판정 + RAM 주소 -----------------------------------------
    wire in_c0 = (x >= X0) && (x < X0 + IMG);
    wire in_c1 = (x >= X1) && (x < X1 + IMG);
    wire in_c2 = (x >= X2) && (x < X2 + IMG);
    wire [1:0]  col = in_c1 ? 2'd1 : in_c2 ? 2'd2 : 2'd0;
    wire        in_col = in_c0 | in_c1 | in_c2;
    wire [11:0] lx = x - (in_c1 ? X1 : in_c2 ? X2 : X0);
    wire [11:0] ly = y - TOP;
    wire [11:0] lly = y - LABEL_Y;

    wire in_img   = in_col && (y >= TOP) && (y < TOP + IMG);
    wire in_label = in_col && (y >= LABEL_Y) && (y < LABEL_Y + 14);
    wire on_edge  = (lx < BORDER) || (lx >= IMG - BORDER) || (ly < BORDER) || (ly >= IMG - BORDER);

    // 라벨: 글자 칸 16x16 (5x7 글자를 2배, 오른쪽/아래 여백 포함)
    wire [7:0] ch       = label_char(col, lx[7:4]);
    wire [2:0] fx       = lx[3:1];
    wire [4:0] glyph    = font5x7(ch, lly[3:1]);
    wire       text_on  = in_label && (fx < 5) && glyph[4 - fx];

    reg de1, hs1, vs1, img1, edge1, text1;
    reg [1:0] col1;
    reg [15:0] err_addr1;                // 오류 맵 주소 = ly * IMG + lx (화면 좌표)
    always @(posedge clk) begin
        // 버퍼 주소 = (STEP*ly) * BUF_W + STEP*lx  (STEP 픽셀마다 솎아 읽기)
        ram_addr <= in_img ? (ly * (STEP * BUF_W) + STEP * lx) : {AW{1'b0}};
        err_addr1 <= in_img ? (ly * IMG + lx) : 16'd0;
        {de1, hs1, vs1}     <= {de0, hs0, vs0};
        {img1, edge1, text1} <= {in_img, on_edge, text_on};
        col1                 <= col;
    end

    // ---- T2: RAM 데이터 도착 ----------------------------------------------
    reg de2, hs2, vs2, img2, edge2, text2;
    reg [1:0] col2;
    reg [15:0] err_addr2;
    always @(posedge clk) begin
        {de2, hs2, vs2}      <= {de1, hs1, vs1};
        {img2, edge2, text2} <= {img1, edge1, text1};
        col2                 <= col1;
        err_addr2            <= err_addr1;
    end

    // ---- 오류 누적 맵 -------------------------------------------------------
    //   T1 주소로 읽고 (T2 에 도착), 타겟2 열을 지나는 T3 에 같은 주소로 다시 쓴다.
    //   세 열이 같은 주소를 읽지만 쓰기는 타겟2 열에서만 하므로 프레임당 주소마다 한 번.
    reg [1:0] errmap_sr;
    reg       vs_d;
    reg [3:0] settle;
    always @(posedge clk) begin
        errmap_sr <= {errmap_sr[0], errmap};
        vs_d      <= vs0;
        if (rst || !errmap_sr[1])
            settle <= 0;
        else if (vs_d && !vs0 && settle != SETTLE)   // vsync 시작마다 (음극성)
            settle <= settle + 1'b1;
    end
    wire acc = (settle == SETTLE);

    wire err_q;
    wire diff     = (tgt1_rdata != tgt2_rdata);
    wire err_mark = acc && (err_q || diff);

    dpram #(.DW(1), .AW(16), .DEPTH(IMG * IMG)) u_errmap (
        .clk_a(clk), .we_a(img2 && col2 == 2'd2), .addr_a(err_addr2), .wdata_a(err_mark), .rdata_a(),
        .clk_b(clk), .addr_b(err_addr1), .rdata_b(err_q)
    );

    // ---- T3: RGB 출력 -----------------------------------------------------
    wire [7:0]  pix = (col2 == 2'd1) ? tgt1_rdata : (col2 == 2'd2) ? tgt2_rdata : src_rdata;
    wire [23:0] edge_color = (col2 == 2'd0) ? 24'h00C040 : (col2 == 2'd1) ? 24'hFF8000 : 24'hFF2020;

    always @(posedge clk) begin
        {de, hsync, vsync} <= {de2, hs2, vs2};
        if (!de2)
            {r, g, b} <= 24'h000000;
        else if (text2)
            {r, g, b} <= edge_color;
        else if (!img2)
            {r, g, b} <= 24'h202020;                       // 배경
        else if (edge2)
            {r, g, b} <= edge_color;                       // 테두리
        else if (col2 == 2'd2 && err_mark)
            {r, g, b} <= 24'hFF0000;                       // 오류 누적 맵 (빨강)
        else                                               // RGB332 -> RGB888
            {r, g, b} <= {pix[7:5], pix[7:5], pix[7:6],
                          pix[4:2], pix[4:2], pix[4:3],
                          pix[1:0], pix[1:0], pix[1:0], pix[1:0]};
    end
endmodule
