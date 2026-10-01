// ---------------------------------------------------------------------------
// dma_naive_tx : CDC 없는 "순진한" DMA 송신 (소스 도메인, clk_src)  ※ 의도적인 버그
//
//   start 펄스를 받으면 소스 버퍼를 주소 0 부터 N-1 까지 매 클럭 하나씩 읽어서
//   {valid, addr, data} 레지스터로 그대로 내보낸다. 받는 쪽(22 MHz)과의 handshake,
//   FIFO, 동기화기가 전혀 없다. 받는 쪽은 이 레지스터를 자기 클럭으로 바로 샘플링한다.
//     - 33 MHz 로 매 클럭 바뀌므로 22 MHz 쪽은 약 1/3 의 픽셀을 놓친다
//     - 버스가 바뀌는 순간 샘플링하면 비트마다 옛 값/새 값이 섞인다 -> 노이즈
// ---------------------------------------------------------------------------
module dma_naive_tx #(
    parameter N  = 160000,
    parameter AW = 18
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start,
    output reg           busy,
    output reg           done,           // 1클럭 펄스
    // 소스 RAM port A (읽기)
    output wire [AW-1:0] mem_addr,
    input  wire [7:0]    mem_rdata,
    // 직접 전송 버스 (소스 도메인 레지스터)
    output reg           n_valid,
    output reg  [AW-1:0] n_addr,
    output reg  [7:0]    n_data
);
    reg [AW-1:0] rd_addr;
    reg          pend;
    reg [AW-1:0] pend_addr;

    wire issue = busy && (rd_addr != N);
    assign mem_addr = rd_addr;

    always @(posedge clk) begin
        if (rst) begin
            busy    <= 1'b0;
            done    <= 1'b0;
            pend    <= 1'b0;
            rd_addr <= 0;
            n_valid <= 1'b0;
        end else begin
            done      <= 1'b0;
            pend      <= issue;
            pend_addr <= rd_addr;

            // RAM 데이터가 도착한 다음 클럭에 그대로 버스로
            n_valid <= pend;
            if (pend) begin
                n_addr <= pend_addr;
                n_data <= mem_rdata;
            end

            if (start && !busy) begin
                busy    <= 1'b1;
                rd_addr <= 0;
            end else if (busy) begin
                if (issue)
                    rd_addr <= rd_addr + 1'b1;
                if (rd_addr == N && pend) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
endmodule
