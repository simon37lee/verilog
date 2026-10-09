// ---------------------------------------------------------------------------
// matrix_engine (v1) : 정적인 글자 격자
//
//   리셋 뒤 첫 수직 귀선 (vblank) 에 셀 RAM 2400 칸을 난수 (xorshift32) 글자 / 밝기로 채우고 끝.
//   화면 경로 (720p 타이밍, 셀 RAM, 글꼴 ROM, 팔레트) 를 확인하는 단계.
//
//   엔진 공통 규칙 (모든 버전): 셀 RAM 은 vblank 동안에만 쓴다 (vblank_start 부터 30 줄 = 49500 클럭).
//   그러면 화면 한 장이 찢어지지 않고, 검사기가 프레임마다 화면 전체를 비교할 수 있다.
// ---------------------------------------------------------------------------
module matrix_engine #(
    parameter NCELL = 2400
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        vblank_start,        // 수직 귀선 시작 펄스
    // 셀 RAM 포트 (읽기 지연 1 클럭)
    output reg         we,
    output reg  [11:0] addr,
    output reg  [11:0] wdata,
    input  wire [11:0] rdata
);
    // 난수: xorshift32 (클럭마다 32 비트가 다 바뀐다. 1 비트씩 미는 LFSR 은 이웃 칸 글자가 비슷해짐)
    reg  [31:0] lfsr;
    wire [31:0] xs1 = lfsr ^ (lfsr << 13);
    wire [31:0] xs2 = xs1 ^ (xs1 >> 17);
    wire [31:0] xs3 = xs2 ^ (xs2 << 5);
    always @(posedge clk)
        if (rst) lfsr <= 32'hACE1_2468;
        else     lfsr <= xs3;

    reg filling, filled;
    always @(posedge clk) begin
        if (rst) begin
            filling <= 1'b0;
            filled  <= 1'b0;
            we      <= 1'b0;
            addr    <= 12'd0;
            wdata   <= 12'd0;
        end else begin
            we <= 1'b0;
            if (vblank_start && !filled) begin
                filling <= 1'b1;
                addr    <= 12'd0;
            end
            if (filling) begin
                we    <= 1'b1;
                wdata <= {lfsr[11:6] | 6'd4, lfsr[5:0]};    // 밝기 4 이상, 글자 0~63
                if (we) addr <= addr + 1'b1;
                if (we && addr == NCELL - 1) begin
                    we      <= 1'b0;
                    filling <= 1'b0;
                    filled  <= 1'b1;
                end
            end
        end
    end
endmodule
