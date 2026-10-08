// ---------------------------------------------------------------------------
// mandel_render : 보기 영역 관리 + 엔진 구동 + 렌더 시간 측정 + 버퍼 교체 (clk_core 도메인, 공통)
//
//   프레임 하나 (FB_W x FB_H) 를 끝없이 반복해서 다시 그린다.
//     S_VIEW  : 보기 영역 (중심, 픽셀 간격) 갱신 (자동 데모 또는 버튼)
//     S_FRAME : 왼쪽 위 좌표 x0 / top 계산, 렌더 시간 0 으로
//     S_RUN   : 엔진 start -> 엔진 done 대기 (픽셀 계산은 버전별 mandel_engine 이 한다)
//     S_SWAP  : 더블 버퍼면 화면 쪽에 교체 요청 -> 다음 vsync 에 교체됐다는 응답을 기다림
//
//   좌표: 코어보다 8 비트 더 정밀한 CW = W + 8 비트 (소수부 CFRAC = FRAC + 8).
//     x0  = cen_re - 160 step,  top = cen_im + 120 step  (위쪽이 +im)
//
//   보기 영역 갱신 (프레임마다 한 번 -> 렌더가 빠를수록 움직임도 빨라진다)
//     자동 데모 : 확대 1/32 씩 하면서 중심을 목표점 (Seahorse Valley) 으로 1/16 씩 당긴다.
//                 32 배에 닿으면 처음 화면 쪽으로 같은 방식으로 축소, 다시 반복
//     수동      : btn_l/r/u/d 4 픽셀씩 이동,  btn_c 확대 (zoom_out = 1 이면 축소), 1/16 씩
//
//   버퍼: 프레임버퍼 주소 = 버퍼 번호 * FB_W*FB_H + 픽셀 번호
//     더블 버퍼 : wr_buf 에 그리고, 끝나면 swap_req 토글 -> swap_ack 가 따라오면 wr_buf 반전
//     단일 버퍼 : 기다리지 않고 같은 버퍼에 계속 그린다 (화면에 그리는 과정이 보임)
//
//   렌더 시간: 엔진 start ~ done, 10 us 단위 BCD 6 자리 (0000.00 ~ 9999.99 ms). 교체 대기는 빠진다.
// ---------------------------------------------------------------------------
module mandel_render #(
    parameter W       = 18,
    parameter FRAC    = W - 4,
    parameter IW      = 8,
    parameter FB_W    = 320,        // 320 x 240 고정 (160 / 120 시프트가 이 값에 맞춰져 있음)
    parameter FB_H    = 240,
    parameter AW      = 18,         // 버퍼 2 개 주소
    parameter CORE_HZ = 50000000
) (
    input  wire          clk,
    input  wire          rst,
    // 버튼 / 스위치 (이미 clk 도메인으로 동기화된 것)
    input  wire          auto_mode,     // 1 = 자동 데모, 0 = 버튼
    input  wire          dbl_buf,       // 1 = 더블 버퍼
    input  wire          btn_l, btn_r, btn_u, btn_d, btn_c,
    input  wire          zoom_out,
    input  wire [IW-1:0] max_iter,
    // 프레임버퍼 쓰기 포트
    output reg           fb_we,
    output reg  [AW-1:0] fb_addr,
    output reg  [IW-1:0] fb_data,
    // 버퍼 교체 핸드셰이크 (swap_ack 는 이미 clk 도메인으로 동기화된 것)
    output reg           wr_buf,        // 지금 그리는 버퍼
    output reg           swap_req,      // 토글: wr_buf 를 화면에 보여 달라
    input  wire          swap_ack,      // 토글: 화면이 바꿨음
    // 상태
    output reg  [23:0]   perf_bcd,      // 마지막 프레임 렌더 시간, 10 us 단위 BCD
    output reg  [15:0]   frames,        // 완성한 프레임 수
    output wire          busy
);
    localparam CW    = W + 8;
    localparam CFRAC = FRAC + 8;
    localparam NPIX  = FB_W * FB_H;
    localparam PW    = 17;

    // 초기 보기 영역: 중심 (-0.5, 0), 가로 3.5 -> step = 3.5 / 320 = 7 / 640
    localparam [CW+3:0] SEVEN = 7;
    localparam [CW-1:0] STEP0 = (SEVEN << CFRAC) / 640;
    localparam [CW-1:0] HALF  = {{(CW-1){1'b0}}, 1'b1} << (CFRAC - 1);
    localparam [CW-1:0] STEP_MAX = STEP0 << 2;       // 수동 축소 한계 (가로 14)
    localparam [CW-1:0] STEP_MIN = STEP0 >> 5;       // 자동 데모 확대 한계 (32 배)

    // 자동 데모 목표점 (-0.743643887, 0.131825904) = Seahorse Valley. 소수부 30 비트 값에서 맞춘다
    localparam signed [63:0] TGT_RE30 = -64'sd798481544;
    localparam signed [63:0] TGT_IM30 =  64'sd141546987;
    localparam signed [63:0] TGT_RE64 = (CFRAC >= 30) ? (TGT_RE30 <<< (CFRAC - 30)) : (TGT_RE30 >>> (30 - CFRAC));
    localparam signed [63:0] TGT_IM64 = (CFRAC >= 30) ? (TGT_IM30 <<< (CFRAC - 30)) : (TGT_IM30 >>> (30 - CFRAC));
    localparam signed [CW-1:0] TGT_RE  = TGT_RE64[CW-1:0];
    localparam signed [CW-1:0] TGT_IM  = TGT_IM64[CW-1:0];
    localparam signed [CW-1:0] HOME_RE = {CW{1'b0}} - HALF;

    // ---- 엔진 (버전별) ---------------------------------------------------------
    reg                 eng_start;
    reg  signed [CW-1:0] x0, top;
    reg        [CW-1:0] step;
    reg        [IW-1:0] max_lat;
    wire                eng_we, eng_done;
    wire       [PW-1:0] eng_addr;
    wire       [IW-1:0] eng_data;

    mandel_engine #(.W(W), .FRAC(FRAC), .IW(IW), .FB_W(FB_W), .FB_H(FB_H), .PW(PW)) u_engine (
        .clk(clk), .rst(rst),
        .start(eng_start), .x0(x0), .top(top), .step(step), .max_iter(max_lat),
        .fb_we(eng_we), .fb_addr(eng_addr), .fb_data(eng_data),
        .done(eng_done), .busy(busy)
    );

    // 엔진 출력 픽셀 번호에 버퍼 시작 주소를 더한다 (1 클럭)
    wire [AW-1:0] base = wr_buf ? NPIX[AW-1:0] : {AW{1'b0}};
    always @(posedge clk) begin
        fb_we   <= eng_we;
        fb_addr <= base + eng_addr;
        fb_data <= eng_data;
    end

    // ---- 보기 영역 ------------------------------------------------------------
    reg signed [CW-1:0] cen_re, cen_im;
    reg                 zooming_in;       // 자동 데모 방향

    // 목표까지 남은 거리의 1/16 (부호 유지)
    wire signed [CW-1:0] goal_re = zooming_in ? TGT_RE : HOME_RE;
    wire signed [CW-1:0] goal_im = zooming_in ? TGT_IM : {CW{1'b0}};
    wire signed [CW-1:0] diff_re = goal_re - cen_re;
    wire signed [CW-1:0] diff_im = goal_im - cen_im;
    wire signed [CW-1:0] pull_re = diff_re >>> 4;
    wire signed [CW-1:0] pull_im = diff_im >>> 4;

    // ---- 상태 -----------------------------------------------------------------
    localparam S_VIEW = 2'd0, S_FRAME = 2'd1, S_RUN = 2'd2, S_SWAP = 2'd3;
    reg [1:0] state;
    reg       eng_done_d;               // 마지막 쓰기가 1 클럭 늦게 나가므로 done 도 맞춰 늦춘다

    // ---- 렌더 시간 (10 us 틱, BCD) ---------------------------------------------
    localparam TICK_DIV = CORE_HZ / 100000;
    reg [15:0] tick_cnt;
    reg [23:0] bcd;
    wire       tick = (tick_cnt == TICK_DIV - 1);

    // BCD 6 자리 +1
    function [23:0] bcd_inc;
        input [23:0] v;
        integer k;
        reg carry;
        begin
            carry = 1'b1;
            for (k = 0; k < 6; k = k + 1) begin
                if (carry) begin
                    if (v[4*k +: 4] == 4'd9) v[4*k +: 4] = 4'd0;
                    else begin v[4*k +: 4] = v[4*k +: 4] + 1'b1; carry = 1'b0; end
                end
            end
            bcd_inc = v;
        end
    endfunction

    always @(posedge clk) begin
        eng_start  <= 1'b0;
        eng_done_d <= eng_done;

        // 렌더 시간 카운터 (S_FRAME 에서 0 으로)
        tick_cnt <= tick ? 16'd0 : tick_cnt + 1'b1;
        if (tick && bcd != 24'h999999) bcd <= bcd_inc(bcd);

        if (rst) begin
            state      <= S_VIEW;
            cen_re     <= HOME_RE;
            cen_im     <= 0;
            step       <= STEP0;
            zooming_in <= 1'b1;
            wr_buf     <= 1'b0;
            swap_req   <= 1'b0;
            perf_bcd   <= 0;
            frames     <= 0;
            tick_cnt   <= 0;
            bcd        <= 0;
        end else begin
            case (state)
                // 보기 영역 갱신 (이전 프레임이 끝난 뒤 한 번)
                S_VIEW: begin
                    if (auto_mode) begin
                        cen_re <= cen_re + pull_re;
                        cen_im <= cen_im + pull_im;
                        if (zooming_in) begin
                            step <= step - (step >> 5);
                            if (step <= STEP_MIN) zooming_in <= 1'b0;
                        end else begin
                            step <= step + (step >> 5);
                            if (step >= STEP0) zooming_in <= 1'b1;
                        end
                    end else begin
                        if (btn_l) cen_re <= cen_re - (step << 2);
                        if (btn_r) cen_re <= cen_re + (step << 2);
                        if (btn_u) cen_im <= cen_im + (step << 2);
                        if (btn_d) cen_im <= cen_im - (step << 2);
                        if (btn_c) begin
                            if (!zoom_out && step > 16)           step <= step - (step >> 4);
                            else if (zoom_out && step < STEP_MAX) step <= step + (step >> 4);
                        end
                    end
                    max_lat <= max_iter;
                    state   <= S_FRAME;
                end
                // 왼쪽 위 좌표 계산: 160 = 128 + 32, 120 = 128 - 8
                S_FRAME: begin
                    x0        <= cen_re - (step << 7) - (step << 5);
                    top       <= cen_im + (step << 7) - (step << 3);
                    eng_start <= 1'b1;
                    tick_cnt  <= 0;
                    bcd       <= 0;
                    state     <= S_RUN;
                end
                S_RUN: if (eng_done_d) begin
                    perf_bcd <= bcd;
                    frames   <= frames + 1'b1;
                    if (dbl_buf) begin
                        swap_req <= ~swap_req;
                        state    <= S_SWAP;
                    end else begin
                        state    <= S_VIEW;
                    end
                end
                // 화면이 방금 그린 버퍼로 바꿀 때까지 (다음 vsync) 기다렸다가 다른 버퍼에 그린다
                S_SWAP: if (swap_ack == swap_req) begin
                    wr_buf <= ~wr_buf;
                    state  <= S_VIEW;
                end
            endcase
        end
    end
endmodule
