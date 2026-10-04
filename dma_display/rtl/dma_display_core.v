// ---------------------------------------------------------------------------
// dma_display_core : 소스 -> 타겟1 (async FIFO, 올바른 CDC)
//                         -> 타겟2 (CDC 없이 직접 연결, 의도적인 버그)
//                    세 버퍼를 640x480 화면에 3등분해 동시에 표시
//
//   클럭 도메인 (서로 asynchronous):
//     clk_src 33 MHz : 체크보드 writer, 소스 버퍼 port A, DMA 읽기
//     clk_tgt 22 MHz : DMA 쓰기, 타겟1/타겟2 버퍼 port A
//     clk_pix 25 MHz : 640x480 디스플레이, 세 버퍼 port B 읽기
//
//   같은 소스 프레임을 두 가지 방법으로 22 MHz 도메인에 넘긴다:
//     타겟1: dma_reader -> {sof, pixel} -> async FIFO (Gray 포인터 + 2FF 동기화)
//            -> dma_writer (흐름 제어 있음, 빠짐없이 순서대로)
//     타겟2: dma_naive_tx 가 33 MHz 로 매 클럭 {valid, addr, data} 레지스터를 바꾸고
//            22 MHz 플립플롭이 그것을 "그냥" 샘플링 (handshake/FIFO/동기화기 없음)
//            -> 펄스 누락, 버스 비트가 섞인 값(skew/metastability) 으로 노이즈 발생
//
//   소스 도메인 프레임 순서: 그리기 -> 타겟1 DMA -> 타겟2 DMA -> 대기
//     (errmap_mode 에서는 대기 대신 다음 틱까지 타겟2 DMA 를 반복)
//
//   타겟2 버스는 모듈 밖으로 나갔다 들어온다 (n2_* 출력 -> t2_* 입력).
//     실제 하드웨어 : 최상위에서 그대로 연결 (dma_display_top.v)
//     시뮬레이션    : 하네스가 배선 지연/메타스테빌리티를 모델링해서 연결
//                     (RTL 시뮬레이션은 모든 비트를 이상적인 0/1 로 다루므로
//                      비동기 샘플링의 비트 섞임을 스스로 재현할 수 없다)
// ---------------------------------------------------------------------------
module dma_display_core #(
    parameter SCROLL       = 1,
    parameter SRC_TICK_DIV = 550_000,     // 33 MHz / 550000 = 60 소스 프레임/초
    // 버퍼 크기: 400 이면 화면에 1/2 로 솎아서, 200 이면 1:1 로 표시 (화면 크기는 항상 200x200)
    //   FPGA 의 Block RAM 이 작으면 200 / AW=16 으로 줄인다 (예: Spartan-6 LX45)
    parameter W            = 400,
    parameter H            = 400,
    parameter AW           = 18           // ceil(log2(W*H))
) (
    input  wire        clk_src,
    input  wire        clk_tgt,
    input  wire        clk_pix,
    input  wire        rst,               // 비동기 리셋 (각 도메인에서 동기화)
    input  wire        errmap_mode,       // 1: 스크롤 멈춤 + 타겟2 오류 누적 맵 표시 (비동기 입력, 스위치 등)
                                          //    소스는 회색 무늬로 바뀌고 타겟2 DMA 는 쉬지 않고 반복한다
    // 영상 출력 (clk_pix)
    output wire [7:0]  r,
    output wire [7:0]  g,
    output wire [7:0]  b,
    output wire        de,
    output wire        hsync,
    output wire        vsync,
    // 타겟2 직접 전송 버스: 소스 도메인 레지스터 출력 (clk_src)
    output wire        n2_valid,
    output wire [AW-1:0] n2_addr,
    output wire [7:0]  n2_data,
    // 타겟2 직접 전송 버스: 타겟 도메인 입력 (동기화기 없음!)
    input  wire        t2_valid,
    input  wire [AW-1:0] t2_addr,
    input  wire [7:0]  t2_data,
    // 타겟1 async FIFO 의 Gray 포인터 (도메인을 건너는 신호). 보통은 *_x -> *_s 로 그대로 연결
    output wire [4:0]  f_wgray_x,         // 쓰기 포인터 (clk_src)
    input  wire [4:0]  f_wgray_s,         // -> clk_tgt 동기화기
    output wire [4:0]  f_rgray_x,         // 읽기 포인터 (clk_tgt)
    input  wire [4:0]  f_rgray_s,         // -> clk_src 동기화기
    // 상태 (clk_tgt) : 타겟1 에 복사 완료된 프레임 수
    output wire [15:0] tgt_frames
);
    localparam N  = W * H;
    localparam SQ = W / 8;                // 8x8 체스판
    localparam FIFO_AW = 4;

    // ---- 도메인별 리셋 동기화 (비동기 assert, 동기 deassert) -----------------
    reg [2:0] rst_src_sr, rst_tgt_sr, rst_pix_sr;
    always @(posedge clk_src or posedge rst) if (rst) rst_src_sr <= 3'b111; else rst_src_sr <= {rst_src_sr[1:0], 1'b0};
    always @(posedge clk_tgt or posedge rst) if (rst) rst_tgt_sr <= 3'b111; else rst_tgt_sr <= {rst_tgt_sr[1:0], 1'b0};
    always @(posedge clk_pix or posedge rst) if (rst) rst_pix_sr <= 3'b111; else rst_pix_sr <= {rst_pix_sr[1:0], 1'b0};
    wire rst_src = rst_src_sr[2];
    wire rst_tgt = rst_tgt_sr[2];
    wire rst_pix = rst_pix_sr[2];

    // =======================================================================
    // 소스 도메인 (33 MHz)
    // =======================================================================
    localparam S_IDLE = 2'd0, S_RENDER = 2'd1, S_COPY = 2'd2, S_COPY2 = 2'd3;
    reg [1:0]  state;
    reg [19:0] tick_cnt;
    reg        tick_pending;
    reg [7:0]  offset;
    reg        w_start, d_start, n_start;

    wire          w_busy, w_done, w_we;
    wire [AW-1:0] w_addr;
    wire [7:0]    w_data;
    wire          d_busy, d_done, d_re;
    wire [AW-1:0] d_addr;
    wire          n_busy, n_done;
    wire [AW-1:0] n_mem_addr;
    wire [7:0]    src_rdata_a;
    wire [FIFO_AW:0] fifo_level;
    wire          fifo_push;
    wire [8:0]    fifo_wdata;

    reg [1:0] freeze_sr;                 // errmap_mode 를 소스 도메인으로 동기화
    always @(posedge clk_src) freeze_sr <= {freeze_sr[0], errmap_mode};
    wire freeze = freeze_sr[1];

    always @(posedge clk_src) begin
        if (rst_src) begin
            state        <= S_IDLE;
            tick_cnt     <= 0;
            tick_pending <= 1'b1;            // 리셋 직후 첫 프레임 바로 시작
            offset       <= 0;
            w_start      <= 1'b0;
            d_start      <= 1'b0;
            n_start      <= 1'b0;
        end else begin
            w_start <= 1'b0;
            d_start <= 1'b0;
            n_start <= 1'b0;

            if (tick_cnt == SRC_TICK_DIV - 1) begin
                tick_cnt     <= 0;
                tick_pending <= 1'b1;
            end else begin
                tick_cnt <= tick_cnt + 1'b1;
            end

            case (state)
                S_IDLE: if (tick_pending) begin
                    tick_pending <= 1'b0;
                    w_start      <= 1'b1;
                    state        <= S_RENDER;
                end
                S_RENDER: if (w_done) begin
                    d_start <= 1'b1;
                    state   <= S_COPY;
                end
                S_COPY: if (d_done) begin
                    n_start <= 1'b1;
                    state   <= S_COPY2;
                end
                S_COPY2: if (n_done) begin
                    if (SCROLL && !freeze)
                        offset <= (offset == 2 * SQ - 1) ? 8'd0 : offset + 1'b1;
                    if (freeze && !tick_pending)
                        n_start <= 1'b1;         // 오류 맵 모드: 다음 틱까지 타겟2 DMA 반복 (버스가 늘 움직임)
                    else
                        state <= S_IDLE;
                end
            endcase
        end
    end

    checker_writer #(.W(W), .H(H), .SQ(SQ), .AW(AW)) u_writer (
        .clk(clk_src), .rst(rst_src), .start(w_start), .offset(offset), .pattern(freeze),
        .busy(w_busy), .done(w_done), .we(w_we), .addr(w_addr), .wdata(w_data)
    );

    dma_reader #(.N(N), .AW(AW), .FIFO_AW(FIFO_AW)) u_dma_rd (
        .clk(clk_src), .rst(rst_src), .start(d_start), .busy(d_busy), .done(d_done),
        .mem_addr(d_addr), .mem_re(d_re), .mem_rdata(src_rdata_a),
        .fifo_level(fifo_level), .fifo_push(fifo_push), .fifo_data(fifo_wdata)
    );

    // 타겟2 용 CDC 없는 DMA (의도적인 버그)
    dma_naive_tx #(.N(N), .AW(AW)) u_naive_tx (
        .clk(clk_src), .rst(rst_src), .start(n_start), .busy(n_busy), .done(n_done),
        .mem_addr(n_mem_addr), .mem_rdata(src_rdata_a),
        .n_valid(n2_valid), .n_addr(n2_addr), .n_data(n2_data)
    );

    // 소스 버퍼: port A 는 writer(쓰기), 타겟1 DMA, 타겟2 DMA 가 시간을 나눠 사용
    wire [AW-1:0] pix_addr;
    wire [7:0]    src_rdata_b, tgt1_rdata_b, tgt2_rdata_b;

    dpram #(.DW(8), .AW(AW), .DEPTH(N)) u_src_buf (
        .clk_a(clk_src), .we_a(w_we), .addr_a(w_we ? w_addr : n_busy ? n_mem_addr : d_addr),
        .wdata_a(w_data), .rdata_a(src_rdata_a),
        .clk_b(clk_pix), .addr_b(pix_addr), .rdata_b(src_rdata_b)
    );

    // =======================================================================
    // 타겟1 경로: async FIFO (올바른 CDC, 33 MHz -> 22 MHz)
    // =======================================================================
    wire       fifo_empty, fifo_pop;
    wire [8:0] fifo_rdata;

    async_fifo #(.DW(9), .AW(FIFO_AW)) u_cdc_fifo (
        .wclk(clk_src), .wrst(rst_src), .winc(fifo_push), .wdata(fifo_wdata),
        .wfull(), .wlevel(fifo_level),
        .rclk(clk_tgt), .rrst(rst_tgt), .rinc(fifo_pop), .rdata(fifo_rdata), .rempty(fifo_empty),
        .wgray_x(f_wgray_x), .wgray_s(f_wgray_s), .rgray_x(f_rgray_x), .rgray_s(f_rgray_s)
    );

    wire          t1_we;
    wire [AW-1:0] t1_addr;
    wire [7:0]    t1_data;

    dma_writer #(.N(N), .AW(AW)) u_dma_wr (
        .clk(clk_tgt), .rst(rst_tgt),
        .fifo_empty(fifo_empty), .fifo_data(fifo_rdata), .fifo_pop(fifo_pop),
        .we(t1_we), .addr(t1_addr), .wdata(t1_data),
        .frame_done(), .frame_count(tgt_frames)
    );

    dpram #(.DW(8), .AW(AW), .DEPTH(N)) u_tgt1_buf (
        .clk_a(clk_tgt), .we_a(t1_we), .addr_a(t1_addr), .wdata_a(t1_data), .rdata_a(),
        .clk_b(clk_pix), .addr_b(pix_addr), .rdata_b(tgt1_rdata_b)
    );

    // =======================================================================
    // 타겟2 경로: CDC 없음 (의도적인 버그)
    //   33 MHz 도메인의 {valid, addr, data} 를 22 MHz 클럭으로 바로 샘플링해서 쓴다.
    //   - 버스가 33 MHz 로 매 클럭 바뀌어 22 MHz 쪽은 일부 픽셀을 놓친다
    //   - 버스가 바뀌는 순간에 샘플링하면 비트마다 옛 값/새 값이 섞인다
    //     -> 엉뚱한 주소에 엉뚱한 값 = 화면 노이즈
    // =======================================================================
    reg          t2_we;
    reg [AW-1:0] t2_waddr;
    reg [7:0]    t2_wdata;
    always @(posedge clk_tgt) begin
        t2_we    <= t2_valid && !rst_tgt;   // 동기화기 없이 바로 사용
        t2_waddr <= t2_addr;
        t2_wdata <= t2_data;
    end

    dpram #(.DW(8), .AW(AW), .DEPTH(N)) u_tgt2_buf (
        .clk_a(clk_tgt), .we_a(t2_we && (t2_waddr < N)), .addr_a(t2_waddr), .wdata_a(t2_wdata), .rdata_a(),
        .clk_b(clk_pix), .addr_b(pix_addr), .rdata_b(tgt2_rdata_b)
    );

    // =======================================================================
    // 디스플레이 도메인 (25 MHz)
    // =======================================================================
    tri_display #(.BUF_W(W), .STEP(W / 200), .AW(AW)) u_disp (
        .clk(clk_pix), .rst(rst_pix), .errmap(errmap_mode),
        .ram_addr(pix_addr), .src_rdata(src_rdata_b),
        .tgt1_rdata(tgt1_rdata_b), .tgt2_rdata(tgt2_rdata_b),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync)
    );
endmodule
