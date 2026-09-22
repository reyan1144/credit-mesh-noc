`timescale 1ns/1ps

import params_pkg::*;

// Synthesizable message-level traffic source for a mesh NI.
module traffic_generator #(
    parameter int MESSAGE_WIDTH = 128,
    parameter int NODE_ID       = 0,
    parameter logic [15:0] LFSR_SEED = 16'h1ACE
)(
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    enable,
    input  logic [7:0]              injection_threshold,
    input  logic                    fixed_dest_enable,
    input  logic [X_ADDR_WIDTH-1:0] fixed_dest_x,
    input  logic [Y_ADDR_WIDTH-1:0] fixed_dest_y,

    output logic [MESSAGE_WIDTH-1:0] tx_message,
    output logic                     tx_valid,
    input  logic                     tx_ready,
    output logic [X_ADDR_WIDTH-1:0]  tx_dest_x,
    output logic [Y_ADDR_WIDTH-1:0]  tx_dest_y,
    output logic [31:0]              packets_accepted
);

    localparam int SOURCE_X = NODE_ID % MESH_X;
    localparam int SOURCE_Y = NODE_ID / MESH_X;

    logic [15:0] lfsr;
    logic [31:0] sequence_number;
    logic [31:0] local_cycle;
    logic [X_ADDR_WIDTH-1:0] candidate_x;
    logic [Y_ADDR_WIDTH-1:0] candidate_y;
    logic [7:0] candidate_node;
    logic [MESSAGE_WIDTH-1:0] candidate_message;

    always_comb begin
        if (fixed_dest_enable) begin
            candidate_x = fixed_dest_x;
            candidate_y = fixed_dest_y;
        end else begin
            candidate_x = lfsr[X_ADDR_WIDTH-1:0];
            candidate_y = lfsr[X_ADDR_WIDTH +: Y_ADDR_WIDTH];
            if ((candidate_x == X_ADDR_WIDTH'(SOURCE_X)) &&
                (candidate_y == Y_ADDR_WIDTH'(SOURCE_Y))) begin
                if (SOURCE_X == MESH_X-1)
                    candidate_x = '0;
                else
                    candidate_x = X_ADDR_WIDTH'(SOURCE_X + 1);
            end
        end

        candidate_node = 8'(candidate_y * MESH_X + candidate_x);
        candidate_message = '0;
        candidate_message[127:112] = 16'hCAFE;
        candidate_message[111:104] = 8'(NODE_ID);
        candidate_message[103:96]  = candidate_node;
        candidate_message[95:64]   = sequence_number;
        candidate_message[63:32]   = local_cycle;
        candidate_message[31:0]    = {lfsr, lfsr ^ 16'h5A5A};
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            lfsr <= (LFSR_SEED == 0) ? 16'h0001 : LFSR_SEED;
            sequence_number <= '0;
            local_cycle <= '0;
            tx_message <= '0;
            tx_valid <= 1'b0;
            tx_dest_x <= '0;
            tx_dest_y <= '0;
            packets_accepted <= '0;
        end else begin
            local_cycle <= local_cycle + 1'b1;
            lfsr <= {lfsr[14:0],
                     lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

            if (tx_valid) begin
                if (tx_ready) begin
                    tx_valid <= 1'b0;
                    sequence_number <= sequence_number + 1'b1;
                    packets_accepted <= packets_accepted + 1'b1;
                end
            end else if (enable && tx_ready &&
                         (lfsr[7:0] < injection_threshold)) begin
                tx_message <= candidate_message;
                tx_dest_x <= candidate_x;
                tx_dest_y <= candidate_y;
                tx_valid <= 1'b1;
            end
        end
    end

    initial begin
        if (MESSAGE_WIDTH < 128)
            $error("traffic_generator: MESSAGE_WIDTH must be at least 128");
        if ((NODE_ID < 0) || (NODE_ID >= MESH_X*MESH_Y))
            $error("traffic_generator: NODE_ID outside mesh");
    end
endmodule
