// ---------------------------------------------------------------------------
// mcb_model (v5, 시뮬레이션 전용) : Spartan-6 MCB 사용자 포트 2 개의 동작 모델 + 1 MB 메모리
//
//   실제 MCB (DDR2 컨트롤러) 는 Verilator 로 돌릴 수 없어서, fb_writer / fb_reader 가 쓰는 신호만
//   같은 규칙으로 흉내 낸다 (UG388).
//     포트 0 (p0_*, clk0) : 쓰기. 명령 FIFO 4 개, 쓰기 데이터 FIFO 64 워드
//                          명령을 꺼낼 때 데이터가 (bl + 1) 워드 다 있어야 한다 (없으면 underrun 오류)
//     포트 1 (p1_*, clk1) : 읽기. 명령 FIFO 4 개, 읽기 데이터 FIFO 64 워드 (first-word-fall-through)
//                          명령을 꺼내고 LAT 클럭 뒤부터 클럭당 한 워드씩 FIFO 에 넣는다 (넘치면 overflow 오류)
//   명령 사이에는 GAP 클럭을 쉰다 (DDR2 지연 흉내). 오류는 $display 로 알리고 err 를 1 로.
//   calib_done 은 리셋 뒤 CAL 클럭 (clk0) 에 1.
// ---------------------------------------------------------------------------
module mcb_model #(
    parameter LAT = 24,
    parameter GAP = 8,
    parameter CAL = 200
) (
    input  wire        rst,
    output reg         calib_done,
    output reg         err,
    // 포트 0 (쓰기)
    input  wire        clk0,
    input  wire        p0_cmd_en,
    input  wire [2:0]  p0_cmd_instr,
    input  wire [5:0]  p0_cmd_bl,
    input  wire [29:0] p0_cmd_byte_addr,
    output wire        p0_cmd_full,
    output wire        p0_cmd_empty,
    input  wire        p0_wr_en,
    input  wire [3:0]  p0_wr_mask,
    input  wire [31:0] p0_wr_data,
    output wire        p0_wr_empty,
    // 포트 1 (읽기)
    input  wire        clk1,
    input  wire        p1_cmd_en,
    input  wire [2:0]  p1_cmd_instr,
    input  wire [5:0]  p1_cmd_bl,
    input  wire [29:0] p1_cmd_byte_addr,
    output wire        p1_cmd_full,
    input  wire        p1_rd_en,
    output wire [31:0] p1_rd_data,
    output wire        p1_rd_empty
);
    reg [31:0] mem [0:262143];               // 1 MB (워드 주소 = 바이트 주소 [19:2])

    // ================= 포트 0: 쓰기 =================
    reg [35:0] c0 [0:3];                     // {instr, bl, addr[19:2] ...} 명령 FIFO
    reg [2:0]  c0_n;
    reg [1:0]  c0_rp, c0_wp;
    reg [31:0] w0 [0:63];
    reg [6:0]  w0_n;
    reg [5:0]  w0_rp, w0_wp;
    reg [6:0]  x0_left;                      // 진행 중인 명령의 남은 워드
    reg [17:0] x0_addr;
    reg [7:0]  x0_gap;
    reg [9:0]  cal_cnt;

    assign p0_cmd_full  = (c0_n == 4);
    assign p0_cmd_empty = (c0_n == 0) && (x0_left == 0);
    assign p0_wr_empty  = (w0_n == 0);

    wire       c0_push = p0_cmd_en;
    wire       c0_pop  = (x0_left == 0) && (x0_gap == 0) && (c0_n != 0);
    wire [35:0] c0_head = c0[c0_rp];
    wire       w0_pop  = (x0_left != 0);

    always @(posedge clk0) begin
        if (rst) begin
            c0_n <= 0; c0_rp <= 0; c0_wp <= 0;
            w0_n <= 0; w0_rp <= 0; w0_wp <= 0;
            x0_left <= 0; x0_gap <= 0;
            cal_cnt <= 0; calib_done <= 1'b0; err <= 1'b0;
        end else begin
            if (cal_cnt != CAL) cal_cnt <= cal_cnt + 1'b1;
            else                calib_done <= 1'b1;

            if (c0_push) begin
                if (c0_n == 4) begin $display("mcb_model: p0 cmd overflow"); err <= 1'b1; end
                if (p0_cmd_instr != 3'b000) begin $display("mcb_model: p0 non-write cmd"); err <= 1'b1; end
                if (p0_cmd_byte_addr[1:0] != 0) begin $display("mcb_model: p0 unaligned"); err <= 1'b1; end
                c0[c0_wp] <= {p0_cmd_instr, 9'd0, p0_cmd_bl, p0_cmd_byte_addr[19:2]};
                c0_wp     <= c0_wp + 1'b1;
            end
            if (p0_wr_en) begin
                if (w0_n == 64) begin $display("mcb_model: p0 write fifo overflow"); err <= 1'b1; end
                w0[w0_wp] <= p0_wr_data;
                w0_wp     <= w0_wp + 1'b1;
            end
            c0_n <= c0_n + c0_push - c0_pop;
            w0_n <= w0_n + p0_wr_en - w0_pop;

            if (x0_gap != 0) x0_gap <= x0_gap - 1'b1;
            if (c0_pop) begin
                if (w0_n < c0_head[23:18] + 1) begin
                    $display("mcb_model: p0 write underrun (have %0d, need %0d)", w0_n, c0_head[23:18] + 1);
                    err <= 1'b1;
                end
                x0_left <= c0_head[23:18] + 1;
                x0_addr <= c0_head[17:0];
                c0_rp   <= c0_rp + 1'b1;
            end
            if (w0_pop) begin
                if (p0_wr_mask != 0) begin $display("mcb_model: p0 mask not supported"); err <= 1'b1; end
                mem[x0_addr] <= w0[w0_rp];
                w0_rp   <= w0_rp + 1'b1;
                x0_addr <= x0_addr + 1'b1;
                x0_left <= x0_left - 1'b1;
                if (x0_left == 1) x0_gap <= GAP;
            end
        end
    end

    // ================= 포트 1: 읽기 =================
    reg [35:0] c1 [0:3];
    reg [2:0]  c1_n;
    reg [1:0]  c1_rp, c1_wp;
    reg [31:0] r1 [0:63];
    reg [6:0]  r1_n;
    reg [5:0]  r1_rp, r1_wp;
    reg [6:0]  x1_left;
    reg [17:0] x1_addr;
    reg [7:0]  x1_wait;                      // 지연 / 쉬는 클럭

    assign p1_cmd_full = (c1_n == 4);
    assign p1_rd_empty = (r1_n == 0);
    assign p1_rd_data  = r1[r1_rp];

    wire       c1_push = p1_cmd_en;
    wire       c1_pop  = (x1_left == 0) && (x1_wait == 0) && (c1_n != 0);
    wire [35:0] c1_head = c1[c1_rp];
    wire       r1_push = (x1_left != 0) && (x1_wait == 0);
    wire       r1_pop  = p1_rd_en && (r1_n != 0);

    always @(posedge clk1) begin
        if (rst) begin
            c1_n <= 0; c1_rp <= 0; c1_wp <= 0;
            r1_n <= 0; r1_rp <= 0; r1_wp <= 0;
            x1_left <= 0; x1_wait <= 0;
        end else begin
            if (c1_push) begin
                if (c1_n == 4) $display("mcb_model: p1 cmd overflow");
                if (p1_cmd_instr != 3'b001) $display("mcb_model: p1 non-read cmd");
                c1[c1_wp] <= {p1_cmd_instr, 9'd0, p1_cmd_bl, p1_cmd_byte_addr[19:2]};
                c1_wp     <= c1_wp + 1'b1;
            end
            if (p1_rd_en && r1_n == 0) $display("mcb_model: p1 read from empty fifo");
            c1_n <= c1_n + c1_push - c1_pop;
            r1_n <= r1_n + r1_push - r1_pop;
            if (r1_pop) r1_rp <= r1_rp + 1'b1;

            if (x1_wait != 0) x1_wait <= x1_wait - 1'b1;
            if (c1_pop) begin
                x1_left <= c1_head[23:18] + 1;
                x1_addr <= c1_head[17:0];
                x1_wait <= LAT;
                c1_rp   <= c1_rp + 1'b1;
            end
            if (r1_push) begin
                if (r1_n == 64) $display("mcb_model: p1 read fifo overflow");
                r1[r1_wp] <= mem[x1_addr];
                r1_wp   <= r1_wp + 1'b1;
                x1_addr <= x1_addr + 1'b1;
                x1_left <= x1_left - 1'b1;
                if (x1_left == 1) x1_wait <= GAP;
            end
        end
    end
endmodule
