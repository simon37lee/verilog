// ---------------------------------------------------------------------------
// fb_writer (v5) : 엔진이 쓰는 픽셀을 줄 단위로 모아서 DDR2 (MCB 포트) 에 버스트로 쓴다 (clk_core 도메인)
//
//   엔진 결과는 링마다 끝나는 순서대로 나와서 픽셀 번호가 뒤섞여 있다. 픽셀 하나씩 DDR2 에 쓰면
//   명령이 너무 많으므로 칩 안에 줄 버퍼 L 줄을 두고, 가장 오래된 줄 (lo_line) 이 다 차면 그 줄을 보낸다.
//
//   줄 버퍼 : 줄 y 는 칸 y mod L 에 들어간다 (L = 16). 칸마다 1024 바이트 (800 사용), 바이트 레인 4 개
//             (레인 = x mod 4) 라서 읽을 때는 32 비트 워드 (픽셀 4 개) 로 나온다
//   생성 한계 : pix_limit = (lo_line + L) * FB_W. 엔진 생성기가 이 번호 앞까지만 만들므로 들어오는 픽셀은
//               언제나 lo_line ~ lo_line + L - 1 줄 안에 있다 (줄 버퍼가 넘칠 수 없다).
//               반복이 많은 픽셀 하나가 가장 오래된 줄을 오래 붙잡으면 생성기가 이 한계에서 기다리므로
//               L 이 작으면 느려질 수 있다 (처음 화면에서는 4 줄과 16 줄 차이가 없었고, 깊은 확대처럼
//               느린 픽셀이 많은 화면을 위한 여유)
//   내보내기 : 줄 하나 = 워드 FB_W/4 개 = BURST 워드짜리 버스트 NB 번.
//              버스트마다: 쓰기 FIFO 가 비기를 기다림 -> 워드 BURST 개를 FIFO 에 넣음 -> 쓰기 명령
//              (MCB 는 명령보다 데이터가 먼저 FIFO 에 있어야 한다)
//   DDR2 주소 : 버퍼 b 의 픽셀 (x, y) = b * BUF_BYTES + y * FB_W + x (바이트), 워드의 아래 바이트가 왼쪽 픽셀
//
//   픽셀 경로 (4 단): A off = 번호 - lo_idx  |  B off * 5243 (DSP)  |  C 줄 rel = 곱 >> 22, 열 = off - rel * 800
//                     |  D 줄 버퍼 쓰기, 칸 개수 +1
//     off < 16 * 800 = 12800 범위에서 (off * 5243) >> 22 = off / 800 이 정확하다 (전부 확인함)
// ---------------------------------------------------------------------------
module fb_writer #(
    parameter FB_W      = 800,
    parameter FB_H      = 600,
    parameter PW        = 19,
    parameter BURST     = 40,                // 워드 (FB_W / 4 의 약수, 64 이하)
    parameter BUF_BYTES = 30'h80000          // 버퍼 하나의 DDR2 영역 (512 KB)
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          calib_done,         // clk 도메인으로 동기화된 것
    // 렌더러
    input  wire          frame_start,        // 프레임 시작 (모든 상태 초기화)
    input  wire          wr_buf,             // 이번 프레임을 쓸 버퍼 (프레임 동안 고정)
    input  wire          pix_we,
    input  wire [PW-1:0] pix_idx,
    input  wire [7:0]    pix_data,
    output reg  [PW-1:0] pix_limit,
    output reg           flushed,            // 마지막 줄까지 MCB 에 넘겼음
    // MCB 포트 (쓰기만 사용)
    output reg           cmd_en,
    output wire [2:0]    cmd_instr,
    output wire [5:0]    cmd_bl,
    output reg  [29:0]   cmd_byte_addr,
    input  wire          cmd_full,
    input  wire          cmd_empty,
    output wire          wr_en,
    output wire [3:0]    wr_mask,
    output wire [31:0]   wr_data,
    input  wire          wr_empty
);
    localparam L     = 16;                   // 줄 버퍼 줄 수 (아래 나눗셈 상수가 16 * 800 범위에 맞춰져 있음)
    localparam WPL   = FB_W / 4;             // 줄당 워드
    localparam NB    = WPL / BURST;          // 줄당 버스트

    assign cmd_instr = 3'b000;               // write
    assign cmd_bl    = BURST - 1;
    assign wr_mask   = 4'b0000;

    // ---- 줄 버퍼 (바이트 레인 4 개, 칸 L 개 x 256 워드) ------------------------------
    reg [7:0] lb0 [0:4095];
    reg [7:0] lb1 [0:4095];
    reg [7:0] lb2 [0:4095];
    reg [7:0] lb3 [0:4095];

    // ---- 상태 -----------------------------------------------------------------
    reg [9:0]    lo_line;                    // 아직 안 보낸 가장 오래된 줄
    reg [PW-1:0] lo_idx;                     // lo_line * FB_W
    reg [29:0]   lo_addr;                    // 그 줄의 DDR2 주소
    reg [9:0]    cnt [0:L-1];                // 칸마다 받은 픽셀 수

    // ---- 픽셀 경로 --------------------------------------------------------------
    // A
    reg          a_we;
    reg [13:0]   a_off;
    reg [9:0]    a_lo;
    reg [7:0]    a_data;
    // B
    reg          b_we;
    reg [13:0]   b_off;
    reg [26:0]   b_prod;
    reg [9:0]    b_lo;
    reg [7:0]    b_data;
    // C
    reg          c_we;
    reg [3:0]    c_slot;
    reg [9:0]    c_col;
    reg [7:0]    c_data;

    wire [PW-1:0] off_full = pix_idx - lo_idx;
    wire [3:0]    b_rel    = b_prod[25:22];

    always @(posedge clk) begin
        a_we   <= pix_we && !rst;
        a_off  <= off_full[13:0];
        a_lo   <= lo_line;
        a_data <= pix_data;

        b_we   <= a_we;
        b_off  <= a_off;
        b_prod <= a_off * 13'd5243;
        b_lo   <= a_lo;
        b_data <= a_data;

        // 800 * rel = 512 rel + 256 rel + 32 rel
        c_we   <= b_we;
        c_slot <= b_lo[3:0] + b_rel;
        c_col  <= b_off - ({b_rel, 9'd0} + {b_rel, 8'd0} + {b_rel, 5'd0});
        c_data <= b_data;

        // D: 줄 버퍼 쓰기
        if (c_we) begin
            case (c_col[1:0])
                2'd0: lb0[{c_slot, c_col[9:2]}] <= c_data;
                2'd1: lb1[{c_slot, c_col[9:2]}] <= c_data;
                2'd2: lb2[{c_slot, c_col[9:2]}] <= c_data;
                2'd3: lb3[{c_slot, c_col[9:2]}] <= c_data;
            endcase
        end
    end

    // ---- 내보내기 ---------------------------------------------------------------
    localparam X_IDLE = 3'd0, X_WAIT = 3'd1, X_FILL = 3'd2, X_CMD = 3'd3, X_NEXT = 3'd4, X_DONE = 3'd5;
    reg [2:0]  xs;
    reg [7:0]  rd_word;                      // 줄 안 워드 번호 (읽기 주소)
    reg [5:0]  fill_cnt;                     // 이번 버스트에 FIFO 에 넣은 워드
    reg [2:0]  burst;                        // 줄 안 버스트 번호
    reg        rd_valid;                     // q 에 이번 클럭 워드가 있다 (= FIFO 쓰기)
    reg [3:0]  done_wait;
    reg [7:0]  q0, q1, q2, q3;
    wire [3:0] lo_slot = lo_line[3:0];
    wire       line_full = (cnt[lo_slot] == FB_W);

    always @(posedge clk) begin
        q0 <= lb0[{lo_slot, rd_word}];
        q1 <= lb1[{lo_slot, rd_word}];
        q2 <= lb2[{lo_slot, rd_word}];
        q3 <= lb3[{lo_slot, rd_word}];
    end
    assign wr_data = {q3, q2, q1, q0};
    assign wr_en   = rd_valid;               // X_FILL 에서 읽은 워드는 다음 클럭 q 에 나온다

    integer i;
    always @(posedge clk) begin
        cmd_en   <= 1'b0;
        rd_valid <= 1'b0;

        if (c_we) cnt[c_slot] <= cnt[c_slot] + 1'b1;

        if (rst || frame_start) begin
            xs        <= X_IDLE;
            lo_line   <= 0;
            lo_idx    <= 0;
            lo_addr   <= wr_buf ? BUF_BYTES : 30'd0;
            pix_limit <= L * FB_W;
            flushed   <= 1'b0;
            rd_valid  <= 1'b0;
            for (i = 0; i < L; i = i + 1) cnt[i] <= 0;
        end else begin
            case (xs)
                X_IDLE: if (lo_line == FB_H) begin
                    done_wait <= 0;
                    xs        <= X_DONE;
                end else if (line_full && calib_done) begin
                    burst   <= 0;
                    rd_word <= 0;
                    xs      <= X_WAIT;
                end
                // 앞 버스트 데이터를 MCB 가 다 가져갈 때까지 (FIFO 64 워드에 BURST 개를 넣을 자리)
                X_WAIT: if (wr_empty && !rd_valid) begin
                    fill_cnt <= 0;
                    xs       <= X_FILL;
                end
                X_FILL: begin
                    rd_valid <= 1'b1;
                    rd_word  <= rd_word + 1'b1;
                    fill_cnt <= fill_cnt + 1'b1;
                    if (fill_cnt == BURST - 1) xs <= X_CMD;
                end
                // 마지막 워드가 FIFO 에 들어간 다음 클럭부터 명령
                X_CMD: if (!rd_valid && !cmd_full) begin
                    cmd_en        <= 1'b1;
                    cmd_byte_addr <= lo_addr + burst * (BURST * 4);
                    burst         <= burst + 1'b1;
                    xs            <= (burst == NB - 1) ? X_NEXT : X_WAIT;
                end
                // 줄 하나 끝: 칸 비우고 다음 줄
                X_NEXT: begin
`ifdef DEBUG_V5
                    if (lo_line[5:0] == 0) $display("fb_writer: line %0d flushed", lo_line);
`endif
                    cnt[lo_slot] <= 0;
                    lo_line      <= lo_line + 1'b1;
                    lo_idx       <= lo_idx + FB_W;
                    lo_addr      <= lo_addr + FB_W;
                    pix_limit    <= pix_limit + FB_W;
                    xs           <= X_IDLE;
                end
                // MCB 가 명령과 데이터를 다 가져가면 끝 (FIFO 상태 신호가 늦게 바뀔 수 있어서 조금 기다린 뒤 본다)
                X_DONE: begin
                    if (done_wait != 4'hF) done_wait <= done_wait + 1'b1;
                    else if (cmd_empty && wr_empty) flushed <= 1'b1;
                end
                default: xs <= X_IDLE;
            endcase
        end
    end
endmodule
