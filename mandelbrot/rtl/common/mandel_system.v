// ---------------------------------------------------------------------------
// mandel_system : Mandelbrot 렌더러 전체 (클럭 생성 / TMDS 를 뺀 부분)
//
//   clk_core (기본 50 MHz) : 버튼 동기화 -> mandel_render (좌표, 스케줄러, 코어) -> 프레임버퍼 쓰기
//   clk_pix  (25 MHz)      : 프레임버퍼 읽기 -> 팔레트 -> 640x480 출력 (mandel_display)
//
//   도메인 사이:
//     - 프레임버퍼  : 듀얼 클럭 Block RAM, 320 x 240 x 8 비트 버퍼 2 개 (1.2 Mbit)
//     - 버퍼 교체   : 렌더러가 swap_req 토글 -> pix 쪽이 다음 vsync 시작에 화면 버퍼를 바꾸고
//                     swap_ack 토글 -> 렌더러가 보고 다른 버퍼에 그리기 시작.
//                     화면이 보여 줄 버퍼 번호는 렌더러의 wr_buf 를 2FF 로 받은 값
//                     (교체를 기다리는 동안 wr_buf 는 바뀌지 않으므로 안정)
//                     단일 버퍼 모드에서는 pix 쪽이 wr_buf 를 그대로 보여 준다 (그리는 과정이 보임)
//     - 렌더 시간   : 24 비트 버스는 토글 핸드셰이크로 넘긴다. core 쪽 hold 레지스터가 바뀐 뒤
//                     토글 비트만 2FF 로 동기화하고, pix 쪽은 토글을 본 뒤에 버스를 읽는다
//                     (그 시점엔 hold 가 이미 여러 클럭 동안 안정). 이 토글 = 렌더 1 프레임 -> fps 계산
//     - 리셋        : 도메인마다 따로 동기화
// ---------------------------------------------------------------------------
module mandel_system #(
    parameter W       = 18,
    parameter CORE_HZ = 50000000,
    parameter VERSION = 1               // 엔진 버전 (화면 표시용, 실제 엔진은 빌드할 때 rtl/vN 으로 고름)
) (
    input  wire        clk_core,
    input  wire        clk_pix,
    input  wire        rst,             // 비동기 리셋 (1 = 리셋)
    // 버튼 / 스위치 (비동기 입력)
    input  wire        btn_l, btn_r, btn_u, btn_d, btn_c,
    input  wire        sw_manual,       // 1 = 버튼 조작, 0 = 자동 데모 (확대/축소 반복)
    input  wire        sw_single,       // 1 = 단일 버퍼 (그리는 과정이 보임), 0 = 더블 버퍼
    input  wire        sw_zoom_out,     // 1 = btn_c 가 축소
    input  wire [1:0]  sw_iter,         // max_iter: 0 = 255, 1 = 127, 2 = 63, 3 = 31
    // 영상 출력 (clk_pix)
    output wire [7:0]  r, g, b,
    output wire        de, hsync, vsync,
    // 상태 / 디버그 (clk_core)
    output wire        fb_we,
    output wire [17:0] fb_waddr,
    output wire [7:0]  fb_wdata,
    output wire [23:0] perf_bcd,
    output wire [15:0] frames,
    output wire        busy
);
    localparam AW = 18;

    // ---- 리셋 동기화 -----------------------------------------------------------
    reg [2:0] rst_core_sr = 3'b111, rst_pix_sr = 3'b111;
    always @(posedge clk_core or posedge rst)
        if (rst) rst_core_sr <= 3'b111; else rst_core_sr <= {rst_core_sr[1:0], 1'b0};
    always @(posedge clk_pix or posedge rst)
        if (rst) rst_pix_sr <= 3'b111; else rst_pix_sr <= {rst_pix_sr[1:0], 1'b0};
    wire rst_core = rst_core_sr[2];
    wire rst_pix  = rst_pix_sr[2];

    // ---- 버튼 / 스위치 -> clk_core (2FF) ----------------------------------------
    reg [9:0] in_s1, in_s2;
    always @(posedge clk_core) begin
        in_s1 <= {sw_manual, sw_single, btn_l, btn_r, btn_u, btn_d, btn_c, sw_zoom_out, sw_iter};
        in_s2 <= in_s1;
    end
    wire [7:0] max_iter = 8'hFF >> in_s2[1:0];

    // ---- 렌더러 -------------------------------------------------------------------
    wire wr_buf, swap_req;
    reg  swap_ack;                       // clk_pix
    reg  [1:0] ack_s;
    always @(posedge clk_core) ack_s <= {ack_s[0], swap_ack};

    mandel_render #(.W(W), .AW(AW), .CORE_HZ(CORE_HZ)) u_render (
        .clk(clk_core), .rst(rst_core),
        .auto_mode(!in_s2[9]), .dbl_buf(!in_s2[8]),
        .btn_l(in_s2[7]), .btn_r(in_s2[6]), .btn_u(in_s2[5]), .btn_d(in_s2[4]), .btn_c(in_s2[3]),
        .zoom_out(in_s2[2]), .max_iter(max_iter),
        .fb_we(fb_we), .fb_addr(fb_waddr), .fb_data(fb_wdata),
        .wr_buf(wr_buf), .swap_req(swap_req), .swap_ack(ack_s[1]),
        .perf_bcd(perf_bcd), .frames(frames), .busy(busy)
    );

    // ---- 프레임버퍼 ---------------------------------------------------------------
    wire [AW-1:0] fb_raddr;
    wire [7:0]    fb_rdata;
    dpram #(.DW(8), .AW(AW), .DEPTH(2 * 320 * 240)) u_fb (
        .clk_a(clk_core), .we_a(fb_we), .addr_a(fb_waddr), .wdata_a(fb_wdata), .rdata_a(),
        .clk_b(clk_pix), .addr_b(fb_raddr), .rdata_b(fb_rdata)
    );

    // ---- 렌더 시간 core -> pix (토글 핸드셰이크) -----------------------------------
    reg [23:0] perf_hold;
    reg        perf_tog;
    reg [15:0] frames_d;
    always @(posedge clk_core) begin
        if (rst_core) begin
            perf_hold <= 0;
            perf_tog  <= 1'b0;
            frames_d  <= 0;
        end else begin
            frames_d <= frames;
            if (frames != frames_d) begin       // 새 프레임 완성 -> perf_bcd 갱신됨
                perf_hold <= perf_bcd;
                perf_tog  <= ~perf_tog;
            end
        end
    end

    reg [2:0]  tog_sync;
    reg [23:0] perf_pix;
    reg        render_done;              // 렌더 1 프레임 완성 (clk_pix 1 클럭 펄스)
    always @(posedge clk_pix) begin
        if (rst_pix) begin
            tog_sync    <= 3'b000;
            perf_pix    <= 0;
            render_done <= 1'b0;
        end else begin
            tog_sync    <= {tog_sync[1:0], perf_tog};
            render_done <= (tog_sync[2] != tog_sync[1]);
            if (tog_sync[2] != tog_sync[1])
                perf_pix <= perf_hold;
        end
    end

    // ---- 버퍼 교체 (clk_pix): vsync 시작에 요청이 와 있으면 화면 버퍼를 바꾸고 응답 ----------
    reg [2:0] req_s;
    reg [1:0] wrbuf_s, single_s;
    reg       front;                     // 더블 버퍼일 때 화면에 보이는 버퍼
    wire      vs_start;                  // mandel_display 의 vsync 시작 (1 클럭 펄스)
    always @(posedge clk_pix) begin
        req_s    <= {req_s[1:0], swap_req};
        wrbuf_s  <= {wrbuf_s[0], wr_buf};
        single_s <= {single_s[0], sw_single};
        if (rst_pix) begin
            front    <= 1'b0;
            swap_ack <= 1'b0;
        end else if (vs_start && req_s[2] != swap_ack) begin
            front    <= wrbuf_s[1];
            swap_ack <= req_s[2];
        end
    end
    wire rd_buf = single_s[1] ? wrbuf_s[1] : front;

    // ---- 화면 -------------------------------------------------------------------
    mandel_display #(.AW(AW), .VERSION(VERSION)) u_disp (
        .clk(clk_pix), .rst(rst_pix),
        .rd_buf(rd_buf), .fb_addr(fb_raddr), .fb_data(fb_rdata),
        .perf_bcd(perf_pix), .render_done(render_done), .vs_start(vs_start),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync)
    );
endmodule
