// ============================================================================
// 16-lane SpMM datapath. Each lane computes one output row and contains
// NUM_MACS parallel MACs, one per output column.
// ============================================================================
module datapath #(
    parameter int unsigned DATA_WIDTH     = 8,
    parameter int unsigned NUM_MACS       = 16,
    parameter int unsigned NUM_ROWS       = 16,
    parameter int unsigned DATA_WIDTH_OUT = 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,

    input  logic [NUM_ROWS-1:0] in_valid_i,
    output logic [NUM_ROWS-1:0] in_ready_o,
    input  logic [NUM_ROWS-1:0][DATA_WIDTH-1:0] data_a_i,
    input  logic [NUM_ROWS-1:0][NUM_MACS-1:0][DATA_WIDTH-1:0] data_b_i,

    // Asserted by the scheduler after every lane has consumed its row.
    input  logic all_inputs_done_i,

    output logic out_valid_o,
    input  logic out_ready_i,
    output logic [NUM_ROWS-1:0][NUM_MACS-1:0][DATA_WIDTH_OUT-1:0] data_out_o
);
    logic [NUM_ROWS-1:0][NUM_MACS-1:0][DATA_WIDTH_OUT-1:0] mac_acc_out;
    logic [NUM_ROWS-1:0] in_hs;
    logic out_hs;

    // No back-pressure is needed during accumulation. Output is produced only
    // after all input lanes are finished.
    assign in_ready_o = {NUM_ROWS{!out_valid_o}};
    assign in_hs = in_valid_i & in_ready_o;
    assign out_hs = out_valid_o && out_ready_i;

    for (genvar lane = 0; lane < NUM_ROWS; lane++) begin : gen_lanes
        for (genvar col = 0; col < NUM_MACS; col++) begin : gen_macs
            mac_int8 #(
                .DATA_WIDTH(DATA_WIDTH),
                .ACC_WIDTH(DATA_WIDTH_OUT)
            ) i_mac (
                .clk   (clk_i),
                .rst_n (rst_ni),
                .clr   (clear_i),
                .en    (in_hs[lane]),
                .a     (data_a_i[lane]),
                .b     (data_b_i[lane][col]),
                .acc   (mac_acc_out[lane][col])
            );
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            data_out_o <= '0;
            out_valid_o <= 1'b0;
        end else if (clear_i) begin
            data_out_o <= '0;
            out_valid_o <= 1'b0;
        end else begin
            if (out_hs)
                out_valid_o <= 1'b0;
            else if (all_inputs_done_i && !out_valid_o) begin
                data_out_o <= mac_acc_out;
                out_valid_o <= 1'b1;
            end
        end
    end
endmodule
