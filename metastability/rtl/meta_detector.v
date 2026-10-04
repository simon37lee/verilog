// ---------------------------------------------------------------------------
// meta_detector : 샘플링 플립플롭의 출력이 "언제" 바뀌었는지 TDC 로 잰다 (clk 도메인)
//
//   d_in -> [sample_ff @clk] -> q1 -> [tdc_chain, clk_s 로 탭 샘플링] -> 탭 패턴
//
//   clk_s 는 clk 와 같은 주파수, 같은 PLL 의 위상만 늦춘 클럭이다.
//   clk 에지 k 에서 q1 이 0 -> 1 로 바뀌면, clk_s 에지 (k + 위상) 에서 그 변화가 몇 탭까지
//   전파됐는지 보인다. 정상이면 늘 거의 같은 탭 수 (clock-to-Q + 배선 지연이 일정),
//   q1 이 메타스테이블이었다가 늦게 결정되면 탭 수가 줄어든다.
//
//   출력 bin = (NT - 1) - 탭 수  -> bin 이 클수록 q1 이 늦게 바뀐 것 (오른쪽 = 늦음)
//   0 -> 1 변화만 잰다 (carry chain 의 상승/하강 지연이 달라서 섞으면 봉우리가 두 개가 됨).
//   0 -> 1 변화는 최소 2 클럭 간격이므로 ev 도 최소 2 클럭 간격이다 (histogram 이 이를 가정).
// ---------------------------------------------------------------------------
module meta_detector #(
    parameter N4 = 64                     // 탭 수 = 4 * N4 (최대 256)
) (
    input  wire       clk,
    input  wire       clk_s,
    input  wire       d_in,               // 샘플링할 신호 (비동기일 수도, 동기일 수도)
    output reg        ev,                 // 1 클럭 펄스: q1 의 0 -> 1 변화 하나를 쟀다
    output reg  [7:0] bin
);
    localparam NT = 4 * N4;

    wire q1;
    sample_ff u_ff1 (.clk(clk), .d(d_in), .q(q1));

    wire [NT-1:0] taps_s;
    tdc_chain #(.N4(N4)) u_chain (.clk_s(clk_s), .din(q1), .taps(taps_s));

    // ---- clk 도메인으로 옮기기 + 변화 검출 (clk 에지 k+1 에 서로 맞춰진다) ----
    reg [NT-1:0] taps_m;
    reg          q1_prev, ev0;
    always @(posedge clk) begin
        taps_m  <= taps_s;                // clk_s 에지 (k + 위상) 에 잡힌 값
        q1_prev <= q1;
        ev0     <= q1 && !q1_prev;        // 에지 k 에서 0 -> 1
    end

    // ---- 1 의 개수 (3 단 파이프라인) + bin 계산 1 단 ---------------------------
    localparam G1 = NT / 8;               // 8 비트씩
    localparam G2 = (G1 + 7) / 8;         // 다시 8 개씩

    reg [4*G1-1:0] s1;
    reg [7*G2-1:0] s2;
    reg [8:0]      s3;
    reg            ev1, ev2, ev3;
    reg [3:0]      a1;
    reg [6:0]      a2;
    reg [8:0]      a3;
    integer g, k;

    always @(posedge clk) begin
        for (g = 0; g < G1; g = g + 1) begin
            a1 = 0;
            for (k = 0; k < 8; k = k + 1) a1 = a1 + taps_m[8*g+k];
            s1[4*g +: 4] <= a1;
        end
        for (g = 0; g < G2; g = g + 1) begin
            a2 = 0;
            for (k = 0; k < 8; k = k + 1) if (8*g+k < G1) a2 = a2 + s1[4*(8*g+k) +: 4];
            s2[7*g +: 7] <= a2;
        end
        a3 = 0;
        for (g = 0; g < G2; g = g + 1) a3 = a3 + s2[7*g +: 7];
        s3 <= a3;

        // 이벤트도 같이 지연: taps_m(+1) -> s1(+2) -> s2(+3) -> s3(+4) -> bin(+5)
        ev1 <= ev0;
        ev2 <= ev1;
        ev3 <= ev2;
        ev  <= ev3;
        bin <= (s3 >= NT) ? 8'd0 : NT - 1 - s3;
    end
endmodule
