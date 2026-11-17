// ============================================================================
// CSR row-pointer buffer with NUM_READ_PORTS parallel start/end read ports.
// For 256-bit streaming, all 17 pointers fit in one 32-byte beat.
// ============================================================================
module row_ptr_buffer #(
    parameter int unsigned DATA_WIDTH      = 8,
    parameter int unsigned TOTAL_PTRS      = 17,
    parameter int unsigned STREAM_WORD_BIT = 256,
    parameter int unsigned NUM_READ_PORTS  = 16,
    parameter bit          USE_LATCHES     = 0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,
    input  logic write_en_i,
    input  logic [STREAM_WORD_BIT-1:0] wdata_i,
    input  logic [NUM_READ_PORTS-1:0][$clog2(TOTAL_PTRS-1)-1:0] read_row_idx_i,
    output logic [NUM_READ_PORTS-1:0][DATA_WIDTH-1:0] rdata_start_o,
    output logic [NUM_READ_PORTS-1:0][DATA_WIDTH-1:0] rdata_end_o
);
    localparam int unsigned ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH;
    localparam int unsigned NUM_WORDS = (TOTAL_PTRS + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD;
    localparam int unsigned WORD_ADDR_W = (NUM_WORDS > 1) ? $clog2(NUM_WORDS) : 1;
    localparam int unsigned READ_ADDR_W = $clog2(TOTAL_PTRS-1);

    logic [NUM_WORDS-1:0][ELEMS_PER_WORD-1:0][DATA_WIDTH-1:0] mem_q;
    logic [WORD_ADDR_W-1:0] write_word_addr_q;

    for (genvar p = 0; p < NUM_READ_PORTS; p++) begin : gen_read_ports
        wire [READ_ADDR_W:0] idx_start;
        wire [READ_ADDR_W:0] idx_end;
        assign idx_start = {1'b0, read_row_idx_i[p]};
        assign idx_end   = idx_start + 1'b1;
        assign rdata_start_o[p] = mem_q[idx_start / ELEMS_PER_WORD][idx_start % ELEMS_PER_WORD];
        assign rdata_end_o[p]   = mem_q[idx_end   / ELEMS_PER_WORD][idx_end   % ELEMS_PER_WORD];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            write_word_addr_q <= '0;
        else if (clear_i)
            write_word_addr_q <= '0;
        else if (write_en_i) begin
            if (write_word_addr_q == NUM_WORDS-1)
                write_word_addr_q <= '0;
            else
                write_word_addr_q <= write_word_addr_q + 1'b1;
        end
    end

    if (USE_LATCHES) begin : gen_latches
        logic [NUM_WORDS-1:0] clk_w;
        for (genvar w = 0; w < NUM_WORDS; w++) begin : gen_words
            tc_clk_gating i_cg (
                .clk_i(clk_i),
                .en_i((write_en_i && (write_word_addr_q == w)) || clear_i),
                .test_en_i('0),
                .clk_o(clk_w[w])
            );
            for (genvar e = 0; e < ELEMS_PER_WORD; e++) begin : gen_elems
                always_latch begin
                    if (clk_w[w]) begin
                        if (clear_i)
                            mem_q[w][e] = '0;
                        else if ((w*ELEMS_PER_WORD + e) < TOTAL_PTRS)
                            mem_q[w][e] = wdata_i[e*DATA_WIDTH +: DATA_WIDTH];
                    end
                end
            end
        end
    end else begin : gen_flip_flops
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni)
                mem_q <= '0;
            else if (clear_i)
                mem_q <= '0;
            else if (write_en_i) begin
                for (int e = 0; e < ELEMS_PER_WORD; e++) begin
                    if ((write_word_addr_q*ELEMS_PER_WORD + e) < TOTAL_PTRS)
                        mem_q[write_word_addr_q][e] <= wdata_i[e*DATA_WIDTH +: DATA_WIDTH];
                end
            end
        end
    end
endmodule
