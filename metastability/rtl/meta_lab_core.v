// ---------------------------------------------------------------------------
// meta_lab_core : 메타스테빌리티 실험 (벤더 독립 부분)
//
//   같은 측정 회로(meta_detector + histogram) 두 벌 (swap = 0 일 때):
//     A : d_async (링 오실레이터, 진짜 비동기) 를 샘플링
//     B : clk 에 맞춰 4 클럭마다 토글하는 동기 신호 (대조군)
//                 -> 셋업/홀드 구간에 걸릴 일이 없으니 메타스테빌리티가 원천적으로 불가능
//   두 히스토그램을 로그 스케일로 위/아래에 그린다. 봉우리는 둘 다 생기고
//   (클럭 지터와 탭 잡음만큼의 폭), 비동기 쪽에만 봉우리 오른쪽으로 직선으로 떨어지는 꼬리가 생기면
//   그것이 메타스테빌리티(늦게 결정됨, 지수 분포) 이다.
//
//   swap = 1 이면 두 측정 회로의 입력을 맞바꾼다 (A <- 동기, B <- 비동기).
//     그래프 위치는 측정 회로(하드웨어)를, 라벨/색은 신호를 따른다.
//     -> 봉우리 위치가 회로를 따라가면 배선 차이, 꼬리가 신호를 따라가면 메타스테빌리티.
//     swap 이 바뀌면 두 히스토그램을 지우고 다시 쌓는다.
//
//   clk   100 MHz : 샘플링 FF, 이벤트/히스토그램
//   clk_s 100 MHz : clk 와 같은 PLL, 위상만 늦춤 (TDC 탭 샘플링)
//   clk_pix 25 MHz : 화면
// ---------------------------------------------------------------------------
module meta_lab_core #(
    parameter N4        = 64,
    parameter TAP_X10_A = 250,            // 측정 회로별 탭 지연 (0.1 ps), tau 표시용
    parameter TAP_X10_B = 250,
    parameter TAIL_SHIFT = 16             // tau 계산의 꼬리 시작 기준 (tau_engine 참고)
) (
    input  wire        clk,
    input  wire        clk_s,
    input  wire        clk_pix,
    input  wire        rst,               // 비동기 리셋 (리셋하면 히스토그램을 지운다)
    input  wire        d_async,
    input  wire        swap,              // 입력 맞바꾸기 (비동기 입력, 스위치)
    input  wire        zoom,              // 그래프 확대 (비동기 입력, 스위치)
    output wire [7:0]  r,
    output wire [7:0]  g,
    output wire [7:0]  b,
    output wire        de,
    output wire        hsync,
    output wire        vsync,
    output wire [31:0] total_a,
    output wire [31:0] total_b,
    output wire        clearing
);
    reg [2:0] rst_m_sr, rst_pix_sr;
    always @(posedge clk or posedge rst)     if (rst) rst_m_sr   <= 3'b111; else rst_m_sr   <= {rst_m_sr[1:0], 1'b0};
    always @(posedge clk_pix or posedge rst) if (rst) rst_pix_sr <= 3'b111; else rst_pix_sr <= {rst_pix_sr[1:0], 1'b0};
    wire rst_m   = rst_m_sr[2];
    wire rst_pix = rst_pix_sr[2];

    // 대조군: 4 클럭마다 토글 (0 -> 1 변화는 8 클럭마다)
    reg [1:0] div;
    reg       d_sync;
    always @(posedge clk) begin
        if (rst_m) begin
            div    <= 0;
            d_sync <= 1'b0;
        end else begin
            div <= div + 1'b1;
            if (div == 2'd3) d_sync <= ~d_sync;
        end
    end

    // swap 동기화 + 바뀌면 히스토그램 지우기
    reg [2:0] swap_sr;
    always @(posedge clk) swap_sr <= {swap_sr[1:0], swap};
    wire swap_m    = swap_sr[1];
    wire swap_chg  = swap_sr[2] ^ swap_sr[1];

    wire       ev_a, ev_b;
    wire [7:0] bin_a, bin_b;
    meta_detector #(.N4(N4)) u_det_a (.clk(clk), .clk_s(clk_s), .d_in(swap_m ? d_sync : d_async), .ev(ev_a), .bin(bin_a));
    meta_detector #(.N4(N4)) u_det_b (.clk(clk), .clk_s(clk_s), .d_in(swap_m ? d_async : d_sync), .ev(ev_b), .bin(bin_b));

    wire [7:0]  hist_addr;
    wire [31:0] hist_a, hist_b;
    wire        clr_a, clr_b;
    histogram u_hist_a (.clk(clk), .rst(rst_m || swap_chg), .ev(ev_a), .bin(bin_a), .clearing(clr_a), .total(total_a),
                        .rclk(clk_pix), .raddr(hist_addr), .rdata(hist_a));
    histogram u_hist_b (.clk(clk), .rst(rst_m || swap_chg), .ev(ev_b), .bin(bin_b), .clearing(clr_b), .total(total_b),
                        .rclk(clk_pix), .raddr(hist_addr), .rdata(hist_b));
    assign clearing = clr_a | clr_b;

    hist_display #(.TAP_X10_A(TAP_X10_A), .TAP_X10_B(TAP_X10_B), .TAIL_SHIFT(TAIL_SHIFT)) u_disp (
        .clk(clk_pix), .rst(rst_pix), .swap(swap), .zoom(zoom), .hist_addr(hist_addr), .hist_a(hist_a), .hist_b(hist_b),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync)
    );
endmodule
