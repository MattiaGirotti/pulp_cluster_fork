// Unsigned modulo-2^ACC_WIDTH INT8 multiply-accumulate cell.
// Two's-complement INT8 inputs produce the same low ACC_WIDTH bits as
// signed multiplication, matching the accelerator's wrapping INT8 output.
module mac_int8 #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ACC_WIDTH  = 8
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clr,
    input  logic en,
    input  logic [DATA_WIDTH-1:0] a,
    input  logic [DATA_WIDTH-1:0] b,
    output logic [ACC_WIDTH-1:0] acc
);
    logic [2*DATA_WIDTH-1:0] product;
    assign product = a * b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= '0;
        else if (clr) begin
            if (en)
                acc <= product[ACC_WIDTH-1:0];
            else
                acc <= '0;
        end else if (en) begin
            acc <= acc + product[ACC_WIDTH-1:0];
        end
    end
endmodule
