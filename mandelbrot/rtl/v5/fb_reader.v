// ---------------------------------------------------------------------------
// fb_reader (v5) : 화면에 낼 줄을 DDR2 (MCB 포트) 에서 미리 읽어 줄 버퍼에 채운다 (clk_pix 도메인)
//
//   줄 버퍼는 2 줄 (반쪽 2 개 x 256 워드, 워드 = 픽셀 4 개). 화면이 줄 y 를 내보내기 시작할 때
//   mandel_display 가 줄 y+1 을 요청하고, 이 모듈이 그 줄을 다른 반쪽에 채운다 (한 줄 시간 26 us 안에).
//   줄 0 은 마지막 블랭크 줄에서 요청한다.
//
//   읽기: 줄 하나 = 워드 FB_W/4 개 = RB 워드 버스트 NB 번. 버스트마다 명령 하나를 넣고 그 워드가 다
//   들어올 때까지 기다린 뒤 다음 명령 (읽기 FIFO 64 워드가 넘치지 않게).
//   MCB 읽기 FIFO 는 first-word-fall-through: rd_empty 가 0 이면 rd_data 가 이미 맨 앞 워드이고,
//   rd_en 을 올린 클럭에 그 워드를 가져간다.
// ---------------------------------------------------------------------------
module fb_reader #(
    parameter FB_W      = 800,
    parameter RB        = 50,                // 버스트 워드 (FB_W / 4 의 약수, 64 이하)
    parameter BUF_BYTES = 30'h80000
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          calib_done,         // clk 도메인으로 동기화된 것
    // 요청 (mandel_display)
    input  wire          req,
    input  wire [9:0]    req_line,
    input  wire          req_buf,            // 읽을 버퍼
    input  wire          req_half,           // 채울 줄 버퍼 반쪽
    // 줄 버퍼 읽기 (mandel_display, 지연 1 클럭)
    input  wire [8:0]    lb_addr,            // {반쪽, 워드}
    output reg  [31:0]   lb_data,
    // MCB 포트 (읽기만 사용)
    output reg           cmd_en,
    output wire [2:0]    cmd_instr,
    output wire [5:0]    cmd_bl,
    output reg  [29:0]   cmd_byte_addr,
    input  wire          cmd_full,
    output wire          rd_en,
    input  wire [31:0]   rd_data,
    input  wire          rd_empty
);
    localparam WPL = FB_W / 4;
    localparam NB  = WPL / RB;

    assign cmd_instr = 3'b001;               // read
    assign cmd_bl    = RB - 1;

    reg [31:0] lb [0:511];
    always @(posedge clk) lb_data <= lb[lb_addr];

    localparam R_IDLE = 2'd0, R_CMD = 2'd1, R_DATA = 2'd2;
    reg [1:0]  rs;
    reg        half;
    reg [7:0]  word;                         // 줄 안 워드 번호 (줄 버퍼 쓰기 주소)
    reg [5:0]  got;                          // 이번 버스트에 받은 워드
    reg [2:0]  burst;
    reg [29:0] addr;

    assign rd_en = (rs == R_DATA) && !rd_empty;

    always @(posedge clk) begin
        cmd_en <= 1'b0;
        if (rd_en) lb[{half, word}] <= rd_data;

        if (rst) begin
            rs <= R_IDLE;
        end else begin
            case (rs)
                R_IDLE: if (req && calib_done) begin
                    // 줄 시작 주소 = 버퍼 + line * 800 (800 = 512 + 256 + 32)
                    addr  <= (req_buf ? BUF_BYTES : 30'd0)
                           + {req_line, 9'd0} + {req_line, 8'd0} + {req_line, 5'd0};
                    half  <= req_half;
                    word  <= 0;
                    burst <= 0;
                    rs    <= R_CMD;
                end
                R_CMD: if (!cmd_full) begin
                    cmd_en        <= 1'b1;
                    cmd_byte_addr <= addr;
                    addr          <= addr + RB * 4;
                    got           <= 0;
                    rs            <= R_DATA;
                end
                R_DATA: if (rd_en) begin
                    word <= word + 1'b1;
                    got  <= got + 1'b1;
                    if (got == RB - 1) begin
                        burst <= burst + 1'b1;
                        rs    <= (burst == NB - 1) ? R_IDLE : R_CMD;
                    end
                end
                default: rs <= R_IDLE;
            endcase
        end
    end
endmodule
