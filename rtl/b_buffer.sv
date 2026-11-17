// ============================================================================
// Dense B buffer.
// Each 256-bit input beat contains two consecutive 16xINT8 rows of B.
// There are NUM_LANES independent row read ports, one for each SpMM lane.
// ============================================================================
module b_buffer #(
    parameter int unsigned DATA_WIDTH      = 8,
    parameter int unsigned NUM_MACS        = 16,
    parameter int unsigned NUM_B_ROWS      = 16,
    parameter int unsigned STREAM_WORD_BIT = 256,
    parameter int unsigned NUM_LANES       = 16,
    parameter bit          USE_LATCHES     = 0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,
    input  logic write_en_i,
    input  logic [STREAM_WORD_BIT-1:0] wdata_i,
    input  logic [NUM_LANES-1:0][$clog2(NUM_B_ROWS)-1:0] read_row_addr_i,
    output logic [NUM_LANES-1:0][NUM_MACS-1:0][DATA_WIDTH-1:0] rdata_b_o
);
    localparam int unsigned ROW_BITS = NUM_MACS * DATA_WIDTH;
    localparam int unsigned ROWS_PER_WORD = STREAM_WORD_BIT / ROW_BITS;
    localparam int unsigned ROW_ADDR_W = (NUM_B_ROWS > 1) ? $clog2(NUM_B_ROWS) : 1;

    logic [NUM_B_ROWS-1:0][NUM_MACS-1:0][DATA_WIDTH-1:0] mem_q;
    logic [ROW_ADDR_W-1:0] write_row_addr_q;

    for (genvar lane = 0; lane < NUM_LANES; lane++) begin : gen_read_ports
        assign rdata_b_o[lane] = mem_q[read_row_addr_i[lane]];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            write_row_addr_q <= '0;
        else if (clear_i)
            write_row_addr_q <= '0;
        else if (write_en_i) begin
            if ((write_row_addr_q + ROWS_PER_WORD) >= NUM_B_ROWS)
                write_row_addr_q <= '0;
            else
                write_row_addr_q <= write_row_addr_q + ROWS_PER_WORD;
        end
    end

    if (USE_LATCHES) begin : gen_latches
        logic [NUM_B_ROWS-1:0] clk_row;
        for (genvar r = 0; r < NUM_B_ROWS; r++) begin : gen_rows
            wire row_in_beat;
            wire [ROW_ADDR_W-1:0] row_offset;
            assign row_in_beat = (r >= write_row_addr_q) && (r < (write_row_addr_q + ROWS_PER_WORD));
            assign row_offset = r - write_row_addr_q;
            tc_clk_gating i_cg (
                .clk_i(clk_i),
                .en_i((write_en_i && row_in_beat) || clear_i),
                .test_en_i('0),
                .clk_o(clk_row[r])
            );
            always_latch begin
                if (clk_row[r]) begin
                    if (clear_i)
                        mem_q[r] = '0;
                    else if (row_in_beat)
                        for (int c = 0; c < NUM_MACS; c++)
                            mem_q[r][c] = wdata_i[(row_offset*ROW_BITS) + c*DATA_WIDTH +: DATA_WIDTH];
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
                for (int r = 0; r < ROWS_PER_WORD; r++) begin
                    if ((write_row_addr_q + r) < NUM_B_ROWS) begin
                        for (int c = 0; c < NUM_MACS; c++) begin
                            mem_q[write_row_addr_q + r][c] <=
                                wdata_i[(r*ROW_BITS) + c*DATA_WIDTH +: DATA_WIDTH];
                        end
                    end
                end
            end
        end
    end
endmodule
