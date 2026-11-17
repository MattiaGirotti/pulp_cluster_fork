// ============================================================================
// A buffer for CSR non-zero values.
// 256-bit streamer writes; NUM_LANES independent combinational read ports.
// ============================================================================
module a_buffer #(
    parameter int unsigned DATA_WIDTH      = 8,
    parameter int unsigned TOTAL_NNZ       = 255,
    parameter int unsigned STREAM_WORD_BIT = 256,
    parameter int unsigned NUM_LANES       = 16,
    parameter bit          USE_LATCHES     = 0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,
    input  logic write_en_i,
    input  logic [STREAM_WORD_BIT-1:0] wdata_i,
    input  logic [NUM_LANES-1:0][$clog2(TOTAL_NNZ)-1:0] read_addr_i,
    output logic [NUM_LANES-1:0][DATA_WIDTH-1:0] rdata_a_o
);
    localparam int unsigned ELEMS_PER_WORD = STREAM_WORD_BIT / DATA_WIDTH;
    localparam int unsigned NUM_WORDS = (TOTAL_NNZ + ELEMS_PER_WORD - 1) / ELEMS_PER_WORD;
    localparam int unsigned WORD_ADDR_W = (NUM_WORDS > 1) ? $clog2(NUM_WORDS) : 1;

    logic [NUM_WORDS-1:0][ELEMS_PER_WORD-1:0][DATA_WIDTH-1:0] mem_q;
    logic [WORD_ADDR_W-1:0] write_word_addr_q;

    // Each lane can read a different NNZ value in the same cycle.
    for (genvar lane = 0; lane < NUM_LANES; lane++) begin : gen_read_ports
        wire [((TOTAL_NNZ > 1) ? $clog2(TOTAL_NNZ) : 1)-1:0] word_idx;
        wire [$clog2(ELEMS_PER_WORD)-1:0] elem_idx;
        assign word_idx = read_addr_i[lane] / ELEMS_PER_WORD;
        assign elem_idx = read_addr_i[lane] % ELEMS_PER_WORD;
        assign rdata_a_o[lane] = mem_q[word_idx][elem_idx];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            write_word_addr_q <= '0;
        end else if (clear_i) begin
            write_word_addr_q <= '0;
        end else if (write_en_i) begin
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
                        else
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
                for (int e = 0; e < ELEMS_PER_WORD; e++)
                    mem_q[write_word_addr_q][e] <= wdata_i[e*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    end
endmodule
