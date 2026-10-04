// ---------------------------------------------------------------------------
// histogram : 256 칸 x 32 비트 히스토그램 (Block RAM, clk 도메인에서 누적, rclk 로 읽기)
//
//   ev 가 오면 mem[bin] += 1 (포화). 읽기 -> 다음 클럭 쓰기 2 단이라 ev 는 최소 2 클럭
//   간격이어야 한다 (meta_detector 는 0 -> 1 변화만 내보내므로 만족).
//   리셋 뒤 256 클럭 동안 전부 0 으로 지운다 (clearing).
// ---------------------------------------------------------------------------
module histogram (
    input  wire        clk,
    input  wire        rst,
    input  wire        ev,
    input  wire [7:0]  bin,
    output reg         clearing,
    output reg  [31:0] total,             // 누적 이벤트 수 (포화)
    // 읽기 포트 (디스플레이)
    input  wire        rclk,
    input  wire [7:0]  raddr,
    output wire [31:0] rdata
);
    reg        wr;                        // 지난 클럭에 읽은 칸에 이번 클럭에 쓴다
    reg [7:0]  wbin;
    reg [7:0]  clr_addr;
    wire [31:0] cur;

    wire        we    = clearing || wr;
    wire [7:0]  addr  = clearing ? clr_addr : wr ? wbin : bin;
    wire [31:0] wdata = clearing ? 32'd0 : (&cur) ? cur : cur + 1'b1;

    dpram #(.DW(32), .AW(8), .DEPTH(256)) u_mem (
        .clk_a(clk), .we_a(we), .addr_a(addr), .wdata_a(wdata), .rdata_a(cur),
        .clk_b(rclk), .addr_b(raddr), .rdata_b(rdata)
    );

    always @(posedge clk) begin
        if (rst) begin
            clearing <= 1'b1;
            clr_addr <= 0;
            wr       <= 1'b0;
            total    <= 0;
        end else if (clearing) begin
            clr_addr <= clr_addr + 1'b1;
            if (clr_addr == 8'hFF) clearing <= 1'b0;
        end else begin
            wr   <= ev && !wr;
            wbin <= bin;
            if (ev && !wr && !(&total)) total <= total + 1'b1;
        end
    end
endmodule
