// ============================================================================
// SpMM top: 256-bit logical streamer + 16 parallel compute lanes x 16 MACs.
// The external HCI interface remains at the cluster width (288 bits in the
// supplied testbench); hci_ecc_enc still protects the complete physical port.
// ============================================================================
`include "hci_helpers.svh"

import hci_package::*;
import hwpe_ctrl_package::*;
import spmm_pkg::*;

module spmm_top #(
    parameter int unsigned DATA_WIDTH      = 8,
    parameter int unsigned NUM_MACS        = 16,
    parameter int unsigned NUM_ROWS        = 16,
    parameter int unsigned TOTAL_NNZ       = 255,
    parameter int unsigned TOTAL_PTRS      = 17,
    parameter int unsigned STREAM_WORD_BIT = 256,
    parameter int unsigned DATA_WIDTH_OUT  = 8,
    parameter int unsigned N_CORES         = 8,
    parameter bit          USE_LATCHES     = 0,
    parameter hci_package::hci_size_parameter_t `HCI_SIZE_PARAM(tcdm_master) = hci_package::DEFAULT_HCI_SIZE
) (
    input  logic clk_i,
    input  logic rst_ni,
    output logic [N_CORES-1:0][1:0] evt_o,
    output logic busy_o,
    hci_core_intf.initiator tcdm_master,
    hwpe_ctrl_intf_periph.slave target
);
    localparam int unsigned NNZ_ADDR_W = (TOTAL_NNZ > 1) ? $clog2(TOTAL_NNZ) : 1;
    localparam int unsigned ROW_PTR_ADDR_W = $clog2(TOTAL_PTRS-1);
    localparam int unsigned C_ROW_BITS = NUM_MACS * DATA_WIDTH_OUT;
    localparam int unsigned C_ROWS_PER_WORD = STREAM_WORD_BIT / C_ROW_BITS;
    localparam int unsigned C_WORDS = (NUM_ROWS + C_ROWS_PER_WORD - 1) / C_ROWS_PER_WORD;
    localparam int unsigned C_WORD_ADDR_W = (C_WORDS > 1) ? $clog2(C_WORDS) : 1;

    // ---------------------------------------------------------------------
    // Virtual HCI interface: streamer operates on low STREAM_WORD_BIT bits.
    // ---------------------------------------------------------------------
    localparam hci_size_parameter_t `HCI_SIZE_PARAM(tcdm_master_raw) =
        `HCI_SIZE_PARAM(tcdm_master);
    `HCI_INTF(tcdm_master_raw, clk_i);

    // Keep ECC on the complete physical cluster data width. For the supplied
    // HwpeNumPorts=9 configuration this is 288 data bits = 9 x 32-bit chunks.
    localparam int unsigned TCDM_ECC_CHUNK_SIZE = 32;
    localparam int unsigned TCDM_ECC_N_CHUNKS =
        HCI_SIZE_tcdm_master.DW / TCDM_ECC_CHUNK_SIZE;

    logic [TCDM_ECC_N_CHUNKS-1:0] tcdm_r_data_single_err;
    logic [TCDM_ECC_N_CHUNKS-1:0] tcdm_r_data_multi_err;
    logic tcdm_r_meta_single_err;
    logic tcdm_r_meta_multi_err;

    hci_ecc_enc #(
        .CHUNK_SIZE                       (TCDM_ECC_CHUNK_SIZE),
        .ENABLE_DATA                      (1'b1),
        .`HCI_SIZE_PARAM(tcdm_target)     (`HCI_SIZE_PARAM(tcdm_master_raw)),
        .`HCI_SIZE_PARAM(tcdm_initiator)  (`HCI_SIZE_PARAM(tcdm_master))
    ) i_spmm_tcdm_ecc_enc (
        .r_data_single_err_o(tcdm_r_data_single_err),
        .r_data_multi_err_o (tcdm_r_data_multi_err),
        .r_meta_single_err_o(tcdm_r_meta_single_err),
        .r_meta_multi_err_o (tcdm_r_meta_multi_err),
        .tcdm_target        (tcdm_master_raw),
        .tcdm_initiator     (tcdm_master)
    );

    // ---------------------------------------------------------------------
    // HWPE control / configuration
    // ---------------------------------------------------------------------
    spmm_config_t accel_config;
    logic accel_config_valid;
    logic target_clear;
    logic streamer_done;
    logic accel_start;
    logic accel_done;

    spmm_target_decoder #(.OpIdWidth(4)) i_spmm_target_decoder (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .target_clear_o(target_clear),
        .config_ready_i(~busy_o),
        .op_done_i(streamer_done),
        .config_valid_o(accel_config_valid),
        .config_o(accel_config),
        .target(target)
    );

    // ---------------------------------------------------------------------
    // Streamer-to-buffer write paths
    // ---------------------------------------------------------------------
    logic a_write_en, b_write_en, col_id_write_en, row_ptr_write_en;
    logic [STREAM_WORD_BIT-1:0] a_wdata, b_wdata, col_id_wdata, row_ptr_wdata;

    // C buffer wide read path: one read word contains two adjacent C rows.
    logic [C_WORD_ADDR_W-1:0] c_read_word_addr;
    logic [STREAM_WORD_BIT-1:0] c_rdata;

    // ---------------------------------------------------------------------
    // Parallel buffer read paths: one independent read port per output row.
    // ---------------------------------------------------------------------
    logic [NUM_ROWS-1:0][ROW_PTR_ADDR_W-1:0] row_ptr_read_addr;
    logic [NUM_ROWS-1:0][7:0] row_ptr_start, row_ptr_end;

    logic [NUM_ROWS-1:0][NNZ_ADDR_W-1:0] a_read_addr, col_id_read_addr;
    logic [NUM_ROWS-1:0][DATA_WIDTH-1:0] a_data, col_id_data;
    logic [NUM_ROWS-1:0][$clog2(NUM_ROWS)-1:0] b_read_row_addr;
    logic [NUM_ROWS-1:0][NUM_MACS-1:0][DATA_WIDTH-1:0] b_data;

    for (genvar lane = 0; lane < NUM_ROWS; lane++) begin : gen_row_ptr_addr
        assign row_ptr_read_addr[lane] = lane;
    end

    // ---------------------------------------------------------------------
    // Scheduler / datapath parallel interfaces
    // ---------------------------------------------------------------------
    logic [NUM_ROWS-1:0] dp_in_valid, dp_in_ready;
    logic dp_init, dp_all_inputs_done;
    logic dp_out_valid, dp_out_ready;
    logic c_buf_write_en;
    logic [NUM_ROWS-1:0][NUM_MACS-1:0][DATA_WIDTH_OUT-1:0] dp_data_out;
    logic dp_clear;

    assign dp_clear = target_clear | dp_init;

    // ---------------------------------------------------------------------
    // 1. 256-bit streamer
    // ---------------------------------------------------------------------
    streamer #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_MACS(NUM_MACS),
        .NUM_ROWS(NUM_ROWS),
        .TOTAL_NNZ(TOTAL_NNZ),
        .TOTAL_PTRS(TOTAL_PTRS),
        .STREAM_WORD_BIT(STREAM_WORD_BIT),
        .DATA_WIDTH_OUT(DATA_WIDTH_OUT)
    ) i_spmm_streamer (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .clear_i(target_clear),
        .start_i(accel_config_valid),
        .busy_o(busy_o),
        .done_o(streamer_done),
        .a_base_addr_i(accel_config.a_base_addr),
        .col_id_base_addr_i(accel_config.col_id_base_addr),
        .row_ptr_base_addr_i(accel_config.row_ptr_base_addr),
        .b_base_addr_i(accel_config.b_base_addr),
        .c_base_addr_i(accel_config.c_base_addr),
        .row_ptr_num_words_i(accel_config.row_ptr_num_words),
        .b_num_words_i(accel_config.b_num_words),
        .tcdm_master(tcdm_master_raw),
        .a_write_en_o(a_write_en),
        .a_wdata_o(a_wdata),
        .b_write_en_o(b_write_en),
        .b_wdata_o(b_wdata),
        .col_id_write_en_o(col_id_write_en),
        .col_id_wdata_o(col_id_wdata),
        .row_ptr_write_en_o(row_ptr_write_en),
        .row_ptr_wdata_o(row_ptr_wdata),
        .c_read_word_addr_o(c_read_word_addr),
        .c_rdata_i(c_rdata),
        .accel_start_o(accel_start),
        .accel_done_i(accel_done)
    );

    // ---------------------------------------------------------------------
    // 2. Input buffers, each with 16 parallel read ports for the 16 lanes.
    // ---------------------------------------------------------------------
    a_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .TOTAL_NNZ(TOTAL_NNZ),
        .STREAM_WORD_BIT(STREAM_WORD_BIT),
        .NUM_LANES(NUM_ROWS),
        .USE_LATCHES(USE_LATCHES)
    ) i_a_buffer (
        .clk_i(clk_i), .rst_ni(rst_ni), .clear_i(target_clear),
        .write_en_i(a_write_en), .wdata_i(a_wdata),
        .read_addr_i(a_read_addr), .rdata_a_o(a_data)
    );

    colID_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .TOTAL_ID(TOTAL_NNZ),
        .STREAM_WORD_BIT(STREAM_WORD_BIT),
        .NUM_LANES(NUM_ROWS),
        .USE_LATCHES(USE_LATCHES)
    ) i_colID_buffer (
        .clk_i(clk_i), .rst_ni(rst_ni), .clear_i(target_clear),
        .write_en_i(col_id_write_en), .wdata_i(col_id_wdata),
        .read_addr_i(col_id_read_addr), .rdata_o(col_id_data)
    );

    b_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_MACS(NUM_MACS),
        .NUM_B_ROWS(NUM_ROWS),
        .STREAM_WORD_BIT(STREAM_WORD_BIT),
        .NUM_LANES(NUM_ROWS),
        .USE_LATCHES(USE_LATCHES)
    ) i_b_buffer (
        .clk_i(clk_i), .rst_ni(rst_ni), .clear_i(target_clear),
        .write_en_i(b_write_en), .wdata_i(b_wdata),
        .read_row_addr_i(b_read_row_addr), .rdata_b_o(b_data)
    );

    row_ptr_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .TOTAL_PTRS(TOTAL_PTRS),
        .STREAM_WORD_BIT(STREAM_WORD_BIT),
        .NUM_READ_PORTS(NUM_ROWS),
        .USE_LATCHES(USE_LATCHES)
    ) i_row_ptr_buffer (
        .clk_i(clk_i), .rst_ni(rst_ni), .clear_i(target_clear),
        .write_en_i(row_ptr_write_en), .wdata_i(row_ptr_wdata),
        .read_row_idx_i(row_ptr_read_addr),
        .rdata_start_o(row_ptr_start), .rdata_end_o(row_ptr_end)
    );

    // ---------------------------------------------------------------------
    // 3. Scheduler: each lane walks the NNZ interval of one CSR row.
    // ---------------------------------------------------------------------
    scheduler #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_MACS(NUM_MACS),
        .NUM_ROWS(NUM_ROWS),
        .TOTAL_NNZ(TOTAL_NNZ),
        .TOTAL_PTRS(TOTAL_PTRS),
        .DATA_WIDTH_OUT(DATA_WIDTH_OUT)
    ) i_scheduler (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .clear_i(target_clear),
        .start_i(accel_start),
        .done_o(accel_done),
        .row_ptr_start_i(row_ptr_start),
        .row_ptr_end_i(row_ptr_end),
        .a_read_addr_o(a_read_addr),
        .col_id_read_addr_o(col_id_read_addr),
        .col_id_i(col_id_data),
        .b_read_row_addr_o(b_read_row_addr),
        .dp_in_valid_o(dp_in_valid),
        .dp_in_ready_i(dp_in_ready),
        .dp_init_o(dp_init),
        .dp_all_inputs_done_o(dp_all_inputs_done),
        .dp_out_valid_i(dp_out_valid),
        .dp_out_ready_o(dp_out_ready),
        .c_write_en_o(c_buf_write_en)
    );

    // ---------------------------------------------------------------------
    // 4. 16 lanes x 16 MACs. Lane l accumulates output row l.
    // ---------------------------------------------------------------------
    datapath #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_MACS(NUM_MACS),
        .NUM_ROWS(NUM_ROWS),
        .DATA_WIDTH_OUT(DATA_WIDTH_OUT)
    ) i_datapath (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .clear_i(dp_clear),
        .in_valid_i(dp_in_valid),
        .in_ready_o(dp_in_ready),
        .data_a_i(a_data),
        .data_b_i(b_data),
        .all_inputs_done_i(dp_all_inputs_done),
        .out_valid_o(dp_out_valid),
        .out_ready_i(dp_out_ready),
        .data_out_o(dp_data_out)
    );

    // ---------------------------------------------------------------------
    // 5. C buffer stores the entire 16x16 result matrix in one commit.
    //    Streamer reads two 16-byte rows as one 256-bit write-back beat.
    // ---------------------------------------------------------------------
    c_buffer #(
        .DATA_WIDTH_OUT(DATA_WIDTH_OUT),
        .NUM_MACS(NUM_MACS),
        .NUM_C_ROWS(NUM_ROWS),
        .STREAM_WORD_BIT(STREAM_WORD_BIT),
        .USE_LATCHES(USE_LATCHES)
    ) i_c_buffer (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .clear_i(target_clear),
        .write_en_i(c_buf_write_en),
        .wdata_i(dp_data_out),
        .read_word_addr_i(c_read_word_addr),
        .rdata_c_o(c_rdata)
    );

    // HWPE event 0 maps to event-unit ID 12 in this cluster testbench.
    always_comb begin
        evt_o = '0;
        evt_o[0][0] = streamer_done;
    end

endmodule
