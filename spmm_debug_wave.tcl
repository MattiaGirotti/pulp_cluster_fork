# Questa waveform setup for SpMM bring-up
# Load after simulation elaboration and before running the test.
onerror {resume}
set S {/pulp_cluster_tb/cluster_i/hwpe_gen/hwpe_subsystem_i/gen_hwpe[3]/gen_spmm/i_spmm_top}

add wave -divider "SPMM control"
add wave -radix unsigned $S/busy_o
add wave -radix unsigned $S/accel_config_valid
add wave -radix unsigned $S/accel_start
add wave -radix unsigned $S/accel_done
add wave -radix unsigned $S/streamer_done
add wave -radix unsigned $S/target_clear
add wave -radix unsigned $S/i_spmm_target_decoder/job_trigger
add wave -radix unsigned $S/i_spmm_target_decoder/job_status

add wave -divider "SPMM streamer FSM"
add wave -radix unsigned $S/i_spmm_streamer/state_q
add wave -radix unsigned $S/i_spmm_streamer/req_cnt_q
add wave -radix unsigned $S/i_spmm_streamer/resp_cnt_q
add wave -radix unsigned $S/i_spmm_streamer/current_addr_q
add wave -radix unsigned $S/i_spmm_streamer/dynamic_words_q

add wave -divider "SPMM raw HCI request-response"
add wave -radix hex $S/tcdm_master_raw.req
add wave -radix hex $S/tcdm_master_raw.gnt
add wave -radix hex $S/tcdm_master_raw.r_valid
add wave -radix hex $S/tcdm_master_raw.add
add wave -radix hex $S/tcdm_master_raw.wen
add wave -radix hex $S/tcdm_master_raw.be
add wave -radix hex $S/tcdm_master_raw.r_data
add wave -radix hex $S/tcdm_master_raw.ecc

add wave -divider "SPMM encoded HCI"
add wave -radix hex $S/tcdm_master.req
add wave -radix hex $S/tcdm_master.gnt
add wave -radix hex $S/tcdm_master.r_valid
add wave -radix hex $S/tcdm_master.add
add wave -radix hex $S/tcdm_master.wen
add wave -radix hex $S/tcdm_master.be
add wave -radix hex $S/tcdm_master.ecc

add wave -divider "SPMM scheduler"
add wave -radix unsigned $S/i_scheduler/current_state
add wave -radix unsigned $S/i_scheduler/row_idx_q
add wave -radix unsigned $S/i_scheduler/nnz_total_q
add wave -radix unsigned $S/i_scheduler/nnz_count_q
add wave -radix unsigned $S/i_scheduler/dp_in_valid_o
add wave -radix unsigned $S/i_scheduler/dp_in_ready_i
add wave -radix unsigned $S/i_scheduler/dp_out_valid_i
add wave -radix unsigned $S/i_scheduler/dp_out_ready_o
add wave -radix unsigned $S/i_scheduler/done_o

configure wave -timelineunits ns
