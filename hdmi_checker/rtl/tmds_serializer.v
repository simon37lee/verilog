// ---------------------------------------------------------------------------
// tmds_serializer : 10:1 직렬화 (벤더 독립, 단순 시프트 레지스터 방식)
//
//   clk_x10 은 clk_pix 의 정확히 10배이며 같은 PLL/MMCM 에서 나와야 한다.
//   10 비트마다 새 워드를 로드하고 LSB 부터 내보낸다.
//   TMDS 클럭 채널은 픽셀 클럭과 같은 주파수의 0000011111 패턴이다.
//
//   ※ 고해상도(720p 이상)에서는 벤더 전용 SERDES(OSERDESE2 등)로 바꾸는 것을 권장.
// ---------------------------------------------------------------------------
module tmds_serializer (
    input  wire       clk_x10,
    input  wire       rst,
    input  wire [9:0] ch0,
    input  wire [9:0] ch1,
    input  wire [9:0] ch2,
    output wire       s_ch0,
    output wire       s_ch1,
    output wire       s_ch2,
    output wire       s_clk
);
    reg [3:0] bit_cnt;
    reg [9:0] sh0, sh1, sh2, shc;

    always @(posedge clk_x10) begin
        if (rst) begin
            bit_cnt <= 0;
            sh0 <= 0; sh1 <= 0; sh2 <= 0; shc <= 0;
        end else if (bit_cnt == 4'd9) begin
            bit_cnt <= 0;
            sh0 <= ch0;
            sh1 <= ch1;
            sh2 <= ch2;
            shc <= 10'b0000011111;
        end else begin
            bit_cnt <= bit_cnt + 1'b1;
            sh0 <= sh0 >> 1;
            sh1 <= sh1 >> 1;
            sh2 <= sh2 >> 1;
            shc <= shc >> 1;
        end
    end

    assign s_ch0 = sh0[0];
    assign s_ch1 = sh1[0];
    assign s_ch2 = sh2[0];
    assign s_clk = shc[0];
endmodule
