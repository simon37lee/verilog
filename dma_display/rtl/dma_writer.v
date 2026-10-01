// ---------------------------------------------------------------------------
// dma_writer : DMA 쓰기 엔진 (타겟 도메인, clk_tgt)
//
//   async FIFO 에 데이터가 있으면 한 클럭에 하나씩 꺼내서 타겟 버퍼에 쓴다.
//   sof 가 붙은 픽셀은 주소 0, 그 다음부터는 주소 +1.
//   프레임 복사가 끝날 때마다(N 번째 픽셀) frame_done 펄스, 프레임 수를 센다.
// ---------------------------------------------------------------------------
module dma_writer #(
    parameter N  = 160000,
    parameter AW = 18
) (
    input  wire          clk,
    input  wire          rst,
    // async FIFO 읽기 포트
    input  wire          fifo_empty,
    input  wire [8:0]    fifo_data,
    output wire          fifo_pop,
    // 타겟 RAM port A (쓰기)
    output reg           we,
    output reg  [AW-1:0] addr,
    output reg  [7:0]    wdata,
    // 상태
    output reg           frame_done,
    output reg  [15:0]   frame_count
);
    assign fifo_pop = !fifo_empty;

    wire sof = fifo_data[8];

    always @(posedge clk) begin
        if (rst) begin
            we          <= 1'b0;
            addr        <= 0;
            frame_done  <= 1'b0;
            frame_count <= 0;
        end else begin
            we         <= fifo_pop;
            frame_done <= 1'b0;
            if (fifo_pop) begin
                addr  <= sof ? {AW{1'b0}} : addr + 1'b1;
                wdata <= fifo_data[7:0];
            end
            // 지난 클럭에 쓴 픽셀이 마지막 주소였으면 프레임 완료
            if (we && addr == N - 1) begin
                frame_done  <= 1'b1;
                frame_count <= frame_count + 1'b1;
            end
        end
    end
endmodule
