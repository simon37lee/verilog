// ---------------------------------------------------------------------------
// tmds_serializer_ddr : 10:1 직렬화 (클럭당 2비트, DDR 출력용, 벤더 독립)
//
//   clk_x5 는 clk_pix 의 정확히 5배이며 같은 PLL 에서 위상이 맞게 나와야 한다.
//   5 클럭마다 새 워드를 로드하고 LSB 부터 2비트씩 내보낸다.
//     s_*[0] : 먼저 나갈 비트 (clk_x5 상승 에지 쪽 반주기)
//     s_*[1] : 나중에 나갈 비트 (하강 에지 쪽 반주기)
//   최상위에서 DDR 출력 플립플롭(Spartan-6 ODDR2 등)에 연결한다.
//   640x480 이면 clk_x5 = 125 MHz 라서 250 MHz 단일 에지 시프트보다 타이밍이 훨씬 여유롭다.
// ---------------------------------------------------------------------------
module tmds_serializer_ddr (
    input  wire       clk_x5,
    input  wire       rst,
    input  wire [9:0] ch0,
    input  wire [9:0] ch1,
    input  wire [9:0] ch2,
    output wire [1:0] s_ch0,
    output wire [1:0] s_ch1,
    output wire [1:0] s_ch2,
    output wire [1:0] s_clk
);
    reg [2:0] cnt;
    reg [9:0] sh0, sh1, sh2, shc;

    always @(posedge clk_x5) begin
        if (rst) begin
            cnt <= 0;
            sh0 <= 0; sh1 <= 0; sh2 <= 0; shc <= 0;
        end else if (cnt == 3'd4) begin
            cnt <= 0;
            sh0 <= ch0;
            sh1 <= ch1;
            sh2 <= ch2;
            shc <= 10'b0000011111;
        end else begin
            cnt <= cnt + 1'b1;
            sh0 <= sh0 >> 2;
            sh1 <= sh1 >> 2;
            sh2 <= sh2 >> 2;
            shc <= shc >> 2;
        end
    end

    assign s_ch0 = sh0[1:0];
    assign s_ch1 = sh1[1:0];
    assign s_ch2 = sh2[1:0];
    assign s_clk = shc[1:0];
endmodule
