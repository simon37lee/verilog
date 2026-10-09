// ---------------------------------------------------------------------------
// mandel_engine (v4) : 픽셀 생성기 + W 비트 8 단 파이프라인 링 RINGS 개 + 2 단계 라운드로빈 쓰기 중재기
//
//   인터페이스는 v1 과 같다 (rtl/v1/mandel_engine.v 머리말 참고).
//   구조는 v3 와 같고 링만 바뀌었다 (rtl/v4/mandel_ring.v: W = 34, 링당 DSP48A1 9 개).
//
//   생성기 -> 링 : 생성기는 다음 픽셀을 레지스터에 만들어 두고, 입력 버퍼가 빈 링 중
//                  번호가 가장 작은 링 하나에 넣는다 (클럭당 1 픽셀)
//   링 -> 프레임버퍼 : 2 단계 라운드로빈 (마지막으로 고른 다음 번호부터 찾으므로 어떤 링도 굶지 않는다)
//                  1) 그룹 (링 GS 개) 마다: 그룹 버퍼가 비어 있으면 출력 버퍼가 찬 링 하나를 골라 옮긴다
//                  2) 그룹 버퍼가 찬 그룹 하나를 골라 프레임버퍼에 쓴다 (클럭당 1 픽셀)
//                  (v3 에서 링 19 개를 한 번에 고르면 타이밍이 안 맞아서 나눈 구조. 링 6 개면 그룹 2 개)
//
//   픽셀 공급과 쓰기가 모두 클럭당 1 개라서, 반복 횟수가 적은 영역 (바깥쪽) 에서는 링이 많아도
//   이 둘이 병목이 된다 (프레임 최소 FB_W * FB_H 클럭). 반복이 많은 영역은 링 수만큼 빨라진다.
//
//   `define RINGS 로 링 개수를 바꿀 수 있다 (기본 6 = DSP48A1 54 개, 칩 전체 58 개)
//     make V=4 DEFS=RINGS=2 check
// ---------------------------------------------------------------------------
module mandel_engine #(
    parameter W    = 34,
    parameter FRAC = W - 4,
    parameter IW   = 8,
    parameter FB_W = 320,
    parameter FB_H = 240,
    parameter PW   = 17
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    input  wire signed [W+7:0] x0,
    input  wire signed [W+7:0] top,
    input  wire        [W+7:0] step,
    input  wire     [IW-1:0] max_iter,
    output reg               fb_we,
    output reg      [PW-1:0] fb_addr,
    output reg      [IW-1:0] fb_data,
    output reg               done,
    output wire              busy
);
    localparam CW   = W + 8;
    localparam NPIX = FB_W * FB_H;
`ifdef RINGS
    localparam N = `RINGS;
`else
    localparam N = 6;
`endif

    // ---- 픽셀 생성기 ----------------------------------------------------------
    reg                 gen_valid;
    reg  [8:0]          px;
    reg  [7:0]          py;
    reg  [PW-1:0]       idx;
    reg  signed [CW-1:0] x0_lat, cur_re, cur_im;
    reg         [CW-1:0] step_lat;
    reg        [IW-1:0] max_lat;

    wire [N-1:0] in_ready;
    wire [N-1:0] in_pick = in_ready & (~in_ready + 1'b1);    // 가장 낮은 번호 하나 (one-hot)
    wire         take    = gen_valid && (in_ready != 0);

    always @(posedge clk) begin
        if (rst) begin
            gen_valid <= 1'b0;
        end else if (start) begin
            gen_valid <= 1'b1;
            x0_lat    <= x0;
            cur_re    <= x0;
            cur_im    <= top;
            step_lat  <= step;
            max_lat   <= max_iter;
            px        <= 0;
            py        <= 0;
            idx       <= 0;
        end else if (take) begin
            idx <= idx + 1'b1;
            if (px == FB_W - 1) begin
                px     <= 0;
                cur_re <= x0_lat;
                cur_im <= cur_im - step_lat;
                if (py == FB_H - 1) gen_valid <= 1'b0;
                else                py <= py + 1'b1;
            end else begin
                px     <= px + 1'b1;
                cur_re <= cur_re + step_lat;
            end
        end
    end

    // ---- 링 N 개 ---------------------------------------------------------------
    wire [N-1:0]    out_valid, out_ready, ring_busy;
    wire [PW+IW-1:0] out_word [0:N-1];

    genvar k;
    generate
        for (k = 0; k < N; k = k + 1) begin : g_ring
            wire [PW-1:0] o_idx;
            wire [IW-1:0] o_iter;
            mandel_ring #(.W(W), .FRAC(FRAC), .IW(IW), .PW(PW)) u_ring (
                .clk(clk), .rst(rst), .max_iter(max_lat),
                .in_valid(gen_valid && in_pick[k]),
                .in_re(cur_re[CW-1 -: W]), .in_im(cur_im[CW-1 -: W]), .in_idx(idx),
                .in_ready(in_ready[k]),
                .out_valid(out_valid[k]), .out_idx(o_idx), .out_iter(o_iter), .out_ready(out_ready[k]),
                .busy(ring_busy[k])
            );
            assign out_word[k] = {o_idx, o_iter};
        end
    endgenerate

    assign busy = (ring_busy != 0);

    // ---- 1 단계: 그룹 안 중재 -> 그룹 버퍼 ---------------------------------------
    localparam GS = 5;                      // 그룹당 링 수
    localparam NG = (N + GS - 1) / GS;      // 그룹 수
    localparam WW = PW + IW;

    wire [NG*GS-1:0] ov_pad = {{(NG*GS-N){1'b0}}, out_valid};   // 마지막 그룹의 빈 자리는 요청 없음
    wire [NG*GS-1:0] or_pad;
    assign out_ready = or_pad[N-1:0];

    reg  [NG-1:0]  gvalid;
    reg  [WW-1:0]  gword [0:NG-1];
    wire [NG-1:0]  tgnt;                    // 2 단계에서 고른 그룹

    genvar g;
    generate
        for (g = 0; g < NG; g = g + 1) begin : g_grp
            wire [GS-1:0] ggnt;
            rr_arb #(.N(GS)) u_arb (
                .clk(clk), .rst(rst),
                .req(gvalid[g] ? {GS{1'b0}} : ov_pad[g*GS +: GS]),
                .gnt(ggnt)
            );
            assign or_pad[g*GS +: GS] = ggnt;

            // 고른 링의 결과 (one-hot AND-OR)
            reg [WW-1:0] sel;
            integer j;
            always @(*) begin
                sel = 0;
                for (j = 0; j < GS; j = j + 1)
                    if (g*GS + j < N)
                        sel = sel | (out_word[g*GS + j] & {WW{ggnt[j]}});
            end

            always @(posedge clk) begin
                if (ggnt != 0) gword[g] <= sel;
                if (rst)            gvalid[g] <= 1'b0;
                else if (ggnt != 0) gvalid[g] <= 1'b1;
                else if (tgnt[g])   gvalid[g] <= 1'b0;
            end
        end
    endgenerate

    // ---- 2 단계: 그룹 중재 -> 쓰기 ------------------------------------------------
    rr_arb #(.N(NG)) u_top (.clk(clk), .rst(rst), .req(gvalid), .gnt(tgnt));

    reg [WW-1:0] tsel;
    integer t;
    always @(*) begin
        tsel = 0;
        for (t = 0; t < NG; t = t + 1)
            tsel = tsel | (gword[t] & {WW{tgnt[t]}});
    end

    // 1 단: 고른 결과 레지스터,  2 단: 프레임버퍼 쓰기 (안쪽 = 0 으로)
    reg          w_valid;
    reg [PW-1:0] w_idx;
    reg [IW-1:0] w_iter;
    reg [PW-1:0] written;

    always @(posedge clk) begin
        w_idx   <= tsel[WW-1:IW];
        w_iter  <= tsel[IW-1:0];
        fb_addr <= w_idx;
        fb_data <= (w_iter == max_lat) ? {IW{1'b0}} : w_iter;
        done    <= 1'b0;
        if (rst) begin
            w_valid <= 1'b0;
            fb_we   <= 1'b0;
            written <= 0;
        end else begin
            w_valid <= (tgnt != 0);
            fb_we   <= w_valid;
            if (start) begin
                written <= 0;
            end else if (w_valid) begin
                written <= written + 1'b1;
                if (written == NPIX - 1) done <= 1'b1;
            end
        end
    end
endmodule
