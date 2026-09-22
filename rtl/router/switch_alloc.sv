`timescale 1ns/1ps

import params_pkg::*;

// One round-robin arbiter per output with packet-level locking.
// A HEAD locks the output to its winning input; BODY flits retain ownership;
// TAIL releases it. HEAD_TAIL never leaves a persistent lock.
module switch_alloc (
    input  logic clk,
    input  logic rst,

    // request bit = input*NUM_PORTS + output
    input  logic [NUM_PORTS*NUM_PORTS-1:0] request_flat,

    // One current FIFO-head flit type per input.
    input  logic [NUM_PORTS*FLIT_TYPE_WIDTH-1:0] flit_type_flat,

    // grant bit = output*NUM_PORTS + input
    output logic [NUM_PORTS*NUM_PORTS-1:0] grant_flat
);

    localparam int OWNER_WIDTH =
        (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS);

    logic request [0:NUM_PORTS-1][0:NUM_PORTS-1];
    logic grant   [0:NUM_PORTS-1][0:NUM_PORTS-1];
    flit_type_t input_flit_type [0:NUM_PORTS-1];

    logic [NUM_PORTS-1:0] arb_req   [0:NUM_PORTS-1];
    logic [NUM_PORTS-1:0] arb_grant [0:NUM_PORTS-1];

    logic                   lock_valid [0:NUM_PORTS-1];
    logic [OWNER_WIDTH-1:0] lock_owner [0:NUM_PORTS-1];

    genvar in_idx, out_idx;
    generate
        for (in_idx = 0; in_idx < NUM_PORTS; in_idx++) begin : gen_input_unpack
            assign input_flit_type[in_idx] = flit_type_t'(
                flit_type_flat[in_idx*FLIT_TYPE_WIDTH +: FLIT_TYPE_WIDTH]);

            for (out_idx = 0; out_idx < NUM_PORTS; out_idx++) begin : gen_request_unpack
                assign request[in_idx][out_idx] =
                    request_flat[in_idx*NUM_PORTS + out_idx];
            end
        end
    endgenerate

    // While unlocked, all requesters participate. While locked, only the
    // packet owner can request that output.
    genvar o, i;
    generate
        for (o = 0; o < NUM_PORTS; o++) begin : gen_output
            for (i = 0; i < NUM_PORTS; i++) begin : gen_request_gate
                assign arb_req[o][i] = lock_valid[o]
                    ? ((lock_owner[o] == OWNER_WIDTH'(i))
                        ? request[i][o] : 1'b0)
                    : request[i][o];

                assign grant[o][i] = arb_grant[o][i];
                assign grant_flat[o*NUM_PORTS + i] = grant[o][i];
            end

            rr_arbiter #(.N(NUM_PORTS)) arbiter (
                .clk(clk),
                .rst(rst),
                .req(arb_req[o]),
                .grant(arb_grant[o])
            );

            always_ff @(posedge clk) begin
                if (rst) begin
                    lock_valid[o] <= 1'b0;
                    lock_owner[o] <= '0;
                end
                else begin
                    for (int winner = 0;
                         winner < NUM_PORTS; winner++) begin
                        if (arb_grant[o][winner]) begin
                            if (lock_valid[o]) begin
                                if ((input_flit_type[winner] == FLIT_TAIL) ||
                                    (input_flit_type[winner] == FLIT_HEAD_TAIL)) begin
                                    lock_valid[o] <= 1'b0;
                                end
                            end
                            else begin
                                if (input_flit_type[winner] == FLIT_HEAD) begin
                                    lock_valid[o] <= 1'b1;
                                    lock_owner[o] <= OWNER_WIDTH'(winner);
                                end
                            end
                        end
                    end
                end
            end
        end
    endgenerate

endmodule
