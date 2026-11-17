// ============================================================================
// Parallel CSR scheduler: one independent NNZ pointer per output row/lane.
// All 16 rows are traversed concurrently; each lane stops at its row_ptr end.
// ============================================================================
module scheduler #(
    parameter int unsigned DATA_WIDTH      = 8,
    parameter int unsigned NUM_MACS        = 16,
    parameter int unsigned NUM_ROWS        = 16,
    parameter int unsigned TOTAL_NNZ       = 255,
    parameter int unsigned TOTAL_PTRS      = 17,
    parameter int unsigned DATA_WIDTH_OUT  = 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic clear_i,
    input  logic start_i,
    output logic done_o,

    input  logic [NUM_ROWS-1:0][7:0] row_ptr_start_i,
    input  logic [NUM_ROWS-1:0][7:0] row_ptr_end_i,

    output logic [NUM_ROWS-1:0][$clog2(TOTAL_NNZ)-1:0] a_read_addr_o,
    output logic [NUM_ROWS-1:0][$clog2(TOTAL_NNZ)-1:0] col_id_read_addr_o,
    input  logic [NUM_ROWS-1:0][DATA_WIDTH-1:0] col_id_i,
    output logic [NUM_ROWS-1:0][$clog2(NUM_ROWS)-1:0] b_read_row_addr_o,

    output logic [NUM_ROWS-1:0] dp_in_valid_o,
    input  logic [NUM_ROWS-1:0] dp_in_ready_i,
    output logic dp_init_o,
    output logic dp_all_inputs_done_o,

    input  logic dp_out_valid_i,
    output logic dp_out_ready_o,
    output logic c_write_en_o
);
    localparam int unsigned NNZ_ADDR_W = (TOTAL_NNZ > 1) ? $clog2(TOTAL_NNZ) : 1;

    typedef enum logic [1:0] {IDLE, RUN_LANES, WAIT_OUTPUT} state_e;
    state_e state_q, state_d;

    logic [NUM_ROWS-1:0][7:0] lane_nnz_ptr_q, lane_nnz_ptr_d;

    assign dp_init_o = (state_q == IDLE) && start_i;

    always_comb begin
        for (int lane = 0; lane < NUM_ROWS; lane++) begin
            a_read_addr_o[lane]     = (lane_nnz_ptr_q[lane] < TOTAL_NNZ) ? lane_nnz_ptr_q[lane][NNZ_ADDR_W-1:0] : '0;
            col_id_read_addr_o[lane]= a_read_addr_o[lane];
            b_read_row_addr_o[lane] = col_id_i[lane][$clog2(NUM_ROWS)-1:0];
            dp_in_valid_o[lane]    = (state_q == RUN_LANES) &&
                                     (lane_nnz_ptr_q[lane] < row_ptr_end_i[lane]);
        end
    end

    assign dp_all_inputs_done_o = (state_q == RUN_LANES) && (dp_in_valid_o == '0);

    always_comb begin
        state_d = state_q;
        lane_nnz_ptr_d = lane_nnz_ptr_q;
        done_o = 1'b0;
        dp_out_ready_o = 1'b0;
        c_write_en_o = 1'b0;

        case (state_q)
            IDLE: begin
                if (start_i) begin
                    for (int lane = 0; lane < NUM_ROWS; lane++)
                        lane_nnz_ptr_d[lane] = row_ptr_start_i[lane];
                    state_d = RUN_LANES;
                end
            end

            RUN_LANES: begin
                for (int lane = 0; lane < NUM_ROWS; lane++) begin
                    if (dp_in_valid_o[lane] && dp_in_ready_i[lane])
                        lane_nnz_ptr_d[lane] = lane_nnz_ptr_q[lane] + 8'd1;
                end
                if (dp_all_inputs_done_o)
                    state_d = WAIT_OUTPUT;
            end

            WAIT_OUTPUT: begin
                dp_out_ready_o = 1'b1;
                if (dp_out_valid_i) begin
                    c_write_en_o = 1'b1;
                    done_o = 1'b1;
                    state_d = IDLE;
                end
            end

            default: state_d = IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            lane_nnz_ptr_q <= '0;
        end else if (clear_i) begin
            state_q <= IDLE;
            lane_nnz_ptr_q <= '0;
        end else begin
            state_q <= state_d;
            lane_nnz_ptr_q <= lane_nnz_ptr_d;
        end
    end
endmodule
