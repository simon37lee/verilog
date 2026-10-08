// ---------------------------------------------------------------------------
// mandel_core (v1) : Mandelbrot 반복 계산 코어 - 반복 1회 / 클럭, 픽셀 1개씩
//
//   z(0) = 0,  z(n+1) = z(n)^2 + c
//     re' = zr^2 - zi^2 + cr
//     im' = 2 zr zi    + ci
//   |z|^2 = zr^2 + zi^2 > 4 가 되거나 n == max_iter 이면 끝, iter = n
//
//   고정소수점: W 비트 부호 있는 수, 소수부 FRAC 비트 (기본 18 비트 Q4.14, 범위 [-8, 8))
//     - 곱셈 3 개 (zr^2, zi^2, zr*zi) 는 2W 비트로 그대로 두고 (Q8.28), 탈출 판정도 2W+1 비트로 한다
//       -> 탈출 판정에는 오버플로가 없다
//     - |z|^2 <= 4 일 때만 다음 z 를 만들므로 |zr^2 - zi^2| <= 4, |2 zr zi| <= 4 이고,
//       |c| < 4 이면 다음 z 도 [-8, 8) 안에 들어간다
//
//   v1 은 가장 단순한 구조: 곱셈기 -> 덧셈 -> 비교 가 모두 한 클럭 안의 조합 회로.
//   클럭이 느려지는 대신 반복 1 회가 1 클럭이다. 한 번에 픽셀 하나만 계산한다.
//
//   start 는 busy = 0 일 때만 받는다. 끝나면 done 이 1 클럭 동안 1, iter 는 다음 start 까지 유지.
// ---------------------------------------------------------------------------
module mandel_core #(
    parameter W    = 18,
    parameter FRAC = W - 4,
    parameter IW   = 8              // 반복 횟수 비트 수
) (
    input  wire                clk,
    input  wire                rst,
    input  wire                start,
    input  wire signed [W-1:0] c_re,
    input  wire signed [W-1:0] c_im,
    input  wire       [IW-1:0] max_iter,
    output reg                 busy,
    output reg                 done,
    output reg        [IW-1:0] iter
);
    reg signed [W-1:0] zr, zi, cr, ci;
    reg        [IW-1:0] n;

    // ---- 반복 1 회 (조합 회로) ---------------------------------------------
    wire signed [2*W-1:0] zr2 = zr * zr;
    wire signed [2*W-1:0] zi2 = zi * zi;
    wire signed [2*W-1:0] zri = zr * zi;

    wire [2*W:0] mag  = {1'b0, zr2} + {1'b0, zi2};          // 둘 다 0 이상
    localparam [2*W:0] FOUR = {{(2*W-2*FRAC-2){1'b0}}, 1'b1, {(2*FRAC+2){1'b0}}};   // 4.0 (소수부 2*FRAC)
    wire escape = (mag > FOUR);

    wire signed [2*W-1:0] dre = zr2 - zi2;
    wire signed [W-1:0] zr_next = dre[FRAC+W-1:FRAC]   + cr;   // (zr^2 - zi^2) >> FRAC
    wire signed [W-1:0] zi_next = zri[FRAC+W-2:FRAC-1] + ci;   // (2 zr zi) >> FRAC

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            zr <= 0; zi <= 0; cr <= 0; ci <= 0;
            n <= 0;
            iter <= 0;
        end else if (!busy) begin
            if (start) begin
                busy <= 1'b1;
                cr <= c_re;
                ci <= c_im;
                zr <= 0;
                zi <= 0;
                n  <= 0;
            end
        end else if (escape || n == max_iter) begin
            busy <= 1'b0;
            done <= 1'b1;
            iter <= n;
        end else begin
            zr <= zr_next;
            zi <= zi_next;
            n  <= n + 1'b1;
        end
    end
endmodule
