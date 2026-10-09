// ---------------------------------------------------------------------------
// mandel_render (v5) : 보기 영역 관리 + 엔진 구동 + 렌더 시간 측정 + 버퍼 교체 (clk_core 도메인)
//
//   공통 mandel_render 와 같고 v5 에서 바뀐 것:
//     - 800 x 600: 처음 step = 3.5 / 800, 왼쪽 위 = 중심 - 400 step / + 300 step
//       (S_CALC 에서 시프트 + 덧셈으로 미리 레지스터에 계산해 둔다. 처음에 모듈에 use_dsp48 = "no" 를
//        붙였더니 아래 엔진의 곱셈까지 전부 LUT 로 바뀌어 칩에 안 들어갔다)
//     - 확대 한계는 해상도가 커서 픽셀 간격이 좁으므로 한 단계 낮춘다 (W = 34 면 2^18 배)
//     - 프레임버퍼가 DDR2 라서 엔진이 끝나도 쓰기 쪽 (fb_writer) 이 마지막 줄까지 내보낼 때 (fb_flushed)
//       까지 기다린다 (S_FLUSH). 렌더 시간도 여기까지
//     - 엔진의 픽셀 생성 한계 pix_limit 를 fb_writer 에서 받아 넘긴다
//
//   프레임 하나 (FB_W x FB_H) 를 끝없이 반복해서 다시 그린다.
//     S_VIEW  : 보기 영역 (중심, 픽셀 간격) 갱신 (자동 데모 또는 버튼)
//     S_CALC  : 화면 절반 (400 step, 300 step) 계산 (2 클럭)
//     S_FRAME : 왼쪽 위 좌표 x0 / top 계산, 렌더 시간 0 으로
//     S_RUN   : 엔진 start -> 엔진 done 대기
//     S_FLUSH : DDR2 쓰기 끝 대기
//     S_SWAP  : 더블 버퍼면 화면 쪽에 교체 요청 -> 다음 vsync 에 교체됐다는 응답을 기다림
//
//   좌표: 코어보다 8 비트 더 정밀한 CW = W + 8 비트 (소수부 CFRAC = FRAC + 8).
//     x0  = cen_re - (FB_W/2) step,  top = cen_im + (FB_H/2) step  (위쪽이 +im)
//
//   보기 영역 갱신 (프레임마다 한 번 -> 렌더가 빠를수록 움직임도 빨라진다)
//     자동 데모 : 확대 1/32 씩 하면서 중심을 목표점 (Seahorse Valley) 으로 1/16 씩 당긴다.
//                 2^ZOOM_LOG 배에 닿으면 중심은 그대로 두고 처음 배율까지 축소, 다시 반복
//                 (리셋 뒤 첫 확대만 처음 화면에서 출발. 축소하면서 처음 중심으로 돌아가게 하면
//                  깊은 확대에서는 첫 프레임에 화면 수천 개 거리를 튀거나, 천천히 가면 가는 길에
//                  메인 카디오이드 안쪽 (전부 검정, 모든 픽셀이 max_iter) 을 지나간다)
//                   W = 18 : 32 배. 픽셀 간격이 코어 LSB 약 5.6 개라서 정밀도 한계가 보이는 곳
//                   W > 18 : 2^(W-15) 배 (W = 34 면 52 만 배, 픽셀 간격 LSB 약 22 개).
//                            그보다 깊으면 목표점 근처가 작은 만델브로 안쪽이라 반복 1023 으로도 거의 검다
//     수동      : btn_l/r/u/d 4 픽셀씩 이동,  btn_c 확대 (zoom_out = 1 이면 축소), 1/16 씩
//
//   버퍼: 프레임버퍼 주소 = 버퍼 번호 * FB_W*FB_H + 픽셀 번호
//     더블 버퍼 : wr_buf 에 그리고, 끝나면 swap_req 토글 -> swap_ack 가 따라오면 wr_buf 반전
//     단일 버퍼 : 기다리지 않고 같은 버퍼에 계속 그린다 (화면에 그리는 과정이 보임)
//
//   반복 횟수: 엔진은 IW 비트 (최대 2^IW - 1) 로 세고, 프레임버퍼에는 8 비트로 접어서 쓴다.
//     팔레트가 주기 64 라서 아래 8 비트만 써도 색은 같다. 단 바깥 점인데 아래 8 비트가 0 이면
//     (256, 512, ...) 안쪽 (검정) 과 겹치므로 같은 색인 64 로 바꾼다.
//
//   렌더 시간: 엔진 start ~ done, 10 us 단위 BCD 6 자리 (0000.00 ~ 9999.99 ms). 교체 대기는 빠진다.
// ---------------------------------------------------------------------------
module mandel_render #(
    parameter W       = 18,
    parameter FRAC    = W - 4,
    parameter IW      = 8,
    parameter FB_W    = 800,
    parameter FB_H    = 600,
    parameter AW      = 20,         // 버퍼 2 개 주소 (검사용 fb_addr)
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
    // DDR2 쓰기 쪽 (fb_writer)
    input  wire [18:0]   pix_limit,     // 엔진이 이 번호보다 작은 픽셀만 만든다
    input  wire          fb_flushed,    // 이번 프레임을 DDR2 에 다 썼음
    output reg           frame_start,   // 엔진 start 와 같은 클럭 (fb_writer 초기화)
    // 프레임버퍼 쓰기 (엔진 출력, 픽셀 번호 + 버퍼 번호 * FB_W * FB_H. fb_writer 와 검사가 본다)
    output reg           fb_we,
    output reg  [AW-1:0] fb_addr,
    output reg  [7:0]    fb_data,
    // 버퍼 교체 핸드셰이크 (swap_ack 는 이미 clk 도메인으로 동기화된 것)
    output reg           wr_buf,        // 지금 그리는 버퍼
    output reg           swap_req,      // 토글: wr_buf 를 화면에 보여 달라
    input  wire          swap_ack,      // 토글: 화면이 바꿨음
    // 상태
    output reg  [23:0]   perf_bcd,      // 마지막 프레임 렌더 시간, 10 us 단위 BCD
    output reg  [15:0]   frames,        // 완성한 프레임 수
    output wire [2:0]    dbg_state,     // 디버그: 상태 (0 VIEW 1 CALC 2 FRAME 3 RUN 4 FLUSH 5 SWAP)
    output wire          busy
);
    localparam CW    = W + 8;
    localparam CFRAC = FRAC + 8;
    localparam NPIX  = FB_W * FB_H;
    localparam PW    = 19;

    // 초기 보기 영역: 중심 (-0.5, 0), 가로 3.5 -> step = 3.5 / FB_W = 7 / (2 FB_W)
    localparam [CW+3:0] SEVEN = 7;
    localparam [CW-1:0] STEP0 = (SEVEN << CFRAC) / (2 * FB_W);
    localparam [CW-1:0] HALF  = {{(CW-1){1'b0}}, 1'b1} << (CFRAC - 1);
    localparam [CW-1:0] STEP_MAX = STEP0 << 2;       // 수동 축소 한계 (가로 14)
    localparam          ZOOM_LOG = ((W <= 18) ? 5 : W - 15) - 1;   // 자동 데모 확대 한계 2^ZOOM_LOG 배
    localparam [CW-1:0] STEP_MIN = STEP0 >> ZOOM_LOG;

    // 자동 데모 목표점 (-0.7436438870371587, 0.1318259042053120) = Seahorse Valley.
    // 소수부 48 비트 값에서 맞춘다 (CFRAC <= 48 이면 충분)
    localparam signed [63:0] TGT_RE48 = -64'sd209317145784806;
    localparam signed [63:0] TGT_IM48 =  64'sd37105693316051;
    localparam signed [63:0] TGT_RE64 = (CFRAC >= 48) ? (TGT_RE48 <<< (CFRAC - 48)) : (TGT_RE48 >>> (48 - CFRAC));
    localparam signed [63:0] TGT_IM64 = (CFRAC >= 48) ? (TGT_IM48 <<< (CFRAC - 48)) : (TGT_IM48 >>> (48 - CFRAC));
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
        .start(eng_start), .x0(x0), .top(top), .step(step), .max_iter(max_lat), .pix_limit(pix_limit),
        .fb_we(eng_we), .fb_addr(eng_addr), .fb_data(eng_data),
        .done(eng_done), .busy(busy)
    );

    // 엔진 출력 픽셀 번호에 버퍼 시작 주소를 더한다 (1 클럭). 반복 횟수는 8 비트로 접는다
    wire [AW-1:0] base = wr_buf ? NPIX[AW-1:0] : {AW{1'b0}};
    wire          lo0  = (eng_data[7:0] == 8'd0) && (eng_data != 0);
    always @(posedge clk) begin
        fb_we   <= eng_we;
        fb_addr <= base + eng_addr;
        fb_data <= lo0 ? 8'd64 : eng_data[7:0];
    end

    // ---- 보기 영역 ------------------------------------------------------------
    reg signed [CW-1:0] cen_re, cen_im;
    reg                 zooming_in;       // 자동 데모 방향

    // 목표까지 남은 거리의 1/16 (부호 유지). 확대할 때만 당긴다
    wire signed [CW-1:0] diff_re = TGT_RE - cen_re;
    wire signed [CW-1:0] diff_im = TGT_IM - cen_im;
    wire signed [CW-1:0] pull_re = diff_re >>> 4;
    wire signed [CW-1:0] pull_im = diff_im >>> 4;

    // ---- 상태 -----------------------------------------------------------------
    localparam S_VIEW = 3'd0, S_CALC = 3'd1, S_FRAME = 3'd2, S_RUN = 3'd3, S_FLUSH = 3'd4, S_SWAP = 3'd5;
    reg [2:0] state;
    assign dbg_state = state;
    reg [1:0] calc_cnt;

    // 화면 절반 = step * 400, step * 300 (800 x 600 고정). step 은 S_VIEW 에서만 바뀌므로
    // S_CALC 에서 몇 클럭 기다리면 맞다.  400 = 256 + 128 + 16,  300 = 256 + 32 + 8 + 4
    reg [CW-1:0] half_w, half_h;
    always @(posedge clk) begin
        half_w <= (step << 8) + (step << 7) + (step << 4);
        half_h <= (step << 8) + (step << 5) + (step << 3) + (step << 2);
    end
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
        eng_start   <= 1'b0;
        frame_start <= 1'b0;
        eng_done_d <= eng_done;

        // 렌더 시간 카운터 (S_FRAME 에서 0 으로)
        tick_cnt <= tick ? 16'd0 : tick_cnt + 1'b1;
        if (tick && bcd != 24'h999999) bcd <= bcd_inc(bcd);

`ifdef DEBUG_V5
        if (eng_start) $display("render: start step %0d", step);
        if (eng_done_d) $display("render: engine done");
`endif
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
                        if (zooming_in) begin
                            cen_re <= cen_re + pull_re;
                            cen_im <= cen_im + pull_im;
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
                    max_lat  <= max_iter;
                    calc_cnt <= 0;
                    state    <= S_CALC;
                end
                S_CALC: begin
                    calc_cnt <= calc_cnt + 1'b1;
                    if (calc_cnt == 2'd2) state <= S_FRAME;
                end
                // 왼쪽 위 좌표
                S_FRAME: begin
                    x0          <= cen_re - half_w;
                    top         <= cen_im + half_h;
                    eng_start   <= 1'b1;
                    frame_start <= 1'b1;
                    tick_cnt  <= 0;
                    bcd       <= 0;
                    state     <= S_RUN;
                end
                S_RUN: if (eng_done_d) state <= S_FLUSH;
                // fb_flushed 는 frame_start 에서 내려가므로 여기 올 때는 이번 프레임 값이다
                S_FLUSH: if (fb_flushed) begin
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
                default: state <= S_VIEW;
            endcase
        end
    end
endmodule
