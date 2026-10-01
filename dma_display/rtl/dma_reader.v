// ---------------------------------------------------------------------------
// dma_reader : DMA 읽기 엔진 (소스 도메인, clk_src)
//
//   start 펄스를 받으면 소스 버퍼를 주소 0 부터 N-1 까지 읽어서 async FIFO 에 넣는다.
//   FIFO 데이터 = {sof, pixel}  (sof: 프레임 첫 픽셀 표시 -> 타겟 쪽 주소 재정렬용)
//
//   RAM 읽기 지연이 1클럭이라 "읽기 요청 -> 다음 클럭 FIFO push" 파이프라인이다.
//   FIFO 가 넘치지 않도록 (현재 사용량 + 진행 중인 요청 1개) < 깊이 일 때만 요청한다.
//   wlevel 은 동기화 지연 때문에 실제보다 크게 보일 수 있지만(안전), 작게 보이지는 않는다.
// ---------------------------------------------------------------------------
module dma_reader #(
    parameter N      = 160000,
    parameter AW     = 18,
    parameter FIFO_AW = 4
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    output reg               busy,
    output reg               done,          // 1클럭 펄스 (마지막 픽셀을 FIFO 에 넣음)
    // 소스 RAM port A (읽기)
    output wire [AW-1:0]     mem_addr,
    output wire              mem_re,        // 이번 클럭에 읽기 요청
    input  wire [7:0]        mem_rdata,
    // async FIFO 쓰기 포트
    input  wire [FIFO_AW:0]  fifo_level,
    output wire              fifo_push,
    output wire [8:0]        fifo_data
);
    localparam DEPTH = 1 << FIFO_AW;

    reg [AW-1:0] rd_addr;       // 다음에 읽을 주소
    reg          pend;          // 지난 클럭에 읽기 요청 -> 이번 클럭에 데이터 도착
    reg          pend_sof;

    wire issue = busy && (rd_addr != N) && ({1'b0, fifo_level} + pend < DEPTH);

    assign mem_addr  = rd_addr;
    assign mem_re    = issue;
    assign fifo_push = pend;
    assign fifo_data = {pend_sof, mem_rdata};

    always @(posedge clk) begin
        if (rst) begin
            busy     <= 1'b0;
            done     <= 1'b0;
            pend     <= 1'b0;
            pend_sof <= 1'b0;
            rd_addr  <= 0;
        end else begin
            done     <= 1'b0;
            pend     <= issue;
            pend_sof <= issue && (rd_addr == 0);
            if (start && !busy) begin
                busy    <= 1'b1;
                rd_addr <= 0;
            end else if (busy) begin
                if (issue)
                    rd_addr <= rd_addr + 1'b1;
                if (rd_addr == N && pend) begin   // 마지막 데이터가 이번 클럭에 push 됨
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
endmodule
