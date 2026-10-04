// ---------------------------------------------------------------------------
// checker_writer : 소스 버퍼에 체크보드 한 프레임을 그려 넣는다 (clk_src)
//
//   start 펄스를 받으면 주소 0 부터 W*H-1 까지 한 클럭에 한 픽셀씩 쓴다.
//   칸 크기 SQ 픽셀 (400 / 50 = 8x8 체스판), offset 만큼 대각선으로 밀린 패턴.
//   곱셈/나눗셈 없이 칸 안 위치 카운터로 색을 정한다.
//   pattern = 1 이면 체크보드 대신 픽셀마다 밝기가 바뀌는 회색 무늬 (x ^ y 의 하위 3비트)
//     -> 이웃 픽셀 값이 거의 항상 달라서, 버스 값이 섞이거나 엉뚱한 주소에 써지면 눈에 띈다
//   픽셀 형식: RGB332 (8비트)
// ---------------------------------------------------------------------------
module checker_writer #(
    parameter       W     = 400,
    parameter       H     = 400,
    parameter       SQ    = 50,
    parameter       AW    = 18,
    parameter [7:0] LIGHT = 8'hFF,       // 흰색
    parameter [7:0] DARK  = 8'h00        // 검정
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start,
    input  wire [7:0]    offset,         // 0 ~ 2*SQ-1
    input  wire          pattern,        // 0: 체크보드, 1: 회색 무늬
    output reg           busy,
    output reg           done,           // 1클럭 펄스
    output reg           we,
    output reg  [AW-1:0] addr,
    output reg  [7:0]    wdata
);
    reg [9:0] x, y;
    reg [7:0] xs, ys;          // 칸 안에서의 위치 (0 ~ SQ-1)
    reg       xp, yp;          // 칸 번호의 홀짝
    reg [7:0] xs0;             // 라인 시작 시 xs
    reg       xp0;

    wire [7:0] off_s = (offset >= SQ) ? offset - SQ : offset;
    wire [2:0] gray  = x[2:0] ^ y[2:0];
    wire       off_p = (offset >= SQ);

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            we   <= 1'b0;
        end else begin
            done <= 1'b0;
            we   <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                x    <= 0;
                y    <= 0;
                xs   <= off_s;  xp  <= off_p;
                xs0  <= off_s;  xp0 <= off_p;
                ys   <= off_s;  yp  <= off_p;
                addr <= {AW{1'b1}};          // 첫 쓰기에서 0 이 되도록
            end else if (busy) begin
                // 현재 (x, y) 픽셀 쓰기
                we    <= 1'b1;
                addr  <= addr + 1'b1;
                wdata <= pattern ? {gray, gray, gray[2:1]}        // RGB332 회색 8단계
                                 : (xp ^ yp) ? DARK : LIGHT;

                // 다음 픽셀 위치
                if (x == W - 1) begin
                    x  <= 0;
                    xs <= xs0;
                    xp <= xp0;
                    if (ys == SQ - 1) begin ys <= 0; yp <= ~yp; end
                    else                     ys <= ys + 1'b1;
                    if (y == H - 1) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                    y <= y + 1'b1;
                end else begin
                    x <= x + 1'b1;
                    if (xs == SQ - 1) begin xs <= 0; xp <= ~xp; end
                    else                     xs <= xs + 1'b1;
                end
            end
        end
    end
endmodule
