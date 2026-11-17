// ============================================================================
// C buffer: stores the complete NUM_ROWS x NUM_MACS output matrix.
// The streamer reads ROWS_PER_BEAT consecutive rows as one wide word.
// ============================================================================
module c_buffer #(
    parameter int unsigned DATA_WIDTH_OUT  = 8,
    parameter int unsigned NUM_MACS        = 16,
    parameter int unsigned NUM_C_ROWS      = 16,
    parameter int unsigned STREAM_WORD_BIT = 256,
    parameter bit          USE_LATCHES     = 0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,
    input  logic write_en_i,
    input  logic [NUM_C_ROWS-1:0][NUM_MACS-1:0][DATA_WIDTH_OUT-1:0] wdata_i,
    input  logic [$clog2((NUM_C_ROWS*NUM_MACS*DATA_WIDTH_OUT + STREAM_WORD_BIT-1)/STREAM_WORD_BIT)-1:0] read_word_addr_i,
    output logic [STREAM_WORD_BIT-1:0] rdata_c_o
);
    localparam int unsigned ROW_BITS = NUM_MACS * DATA_WIDTH_OUT;
    localparam int unsigned ROWS_PER_BEAT = STREAM_WORD_BIT / ROW_BITS;
    localparam int unsigned NUM_WORDS = (NUM_C_ROWS + ROWS_PER_BEAT - 1) / ROWS_PER_BEAT;
    localparam int unsigned WORD_ADDR_W = (NUM_WORDS > 1) ? $clog2(NUM_WORDS) : 1;

    logic [NUM_C_ROWS-1:0][NUM_MACS-1:0][DATA_WIDTH_OUT-1:0] mem_q;

    // Lowest-address row occupies the least-significant ROW_BITS.
    always_comb begin
        rdata_c_o = '0;
        for (int r = 0; r < ROWS_PER_BEAT; r++) begin
            if ((read_word_addr_i*ROWS_PER_BEAT + r) < NUM_C_ROWS)
                rdata_c_o[r*ROW_BITS +: ROW_BITS] =
                    mem_q[read_word_addr_i*ROWS_PER_BEAT + r];
        end
    end

    if (USE_LATCHES) begin : gen_latches
        logic [NUM_C_ROWS-1:0] clk_row;
        for (genvar r = 0; r < NUM_C_ROWS; r++) begin : gen_rows
            tc_clk_gating i_cg (
                .clk_i(clk_i),
                .en_i(write_en_i || clear_i),
                .test_en_i('0),
                .clk_o(clk_row[r])
            );
            always_latch begin
                if (clk_row[r]) begin
                    if (clear_i)
                        mem_q[r] = '0;
                    else if (write_en_i)
                        mem_q[r] = wdata_i[r];
                end
            end
        end
    end else begin : gen_flip_flops
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni)
                mem_q <= '0;
            else if (clear_i)
                mem_q <= '0;
            else if (write_en_i)
                mem_q <= wdata_i;
        end
    end
endmodule
