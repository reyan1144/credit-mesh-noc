`timescale 1ns/1ps

import params_pkg::*;

// 4x4 mesh with one router, NI, and credit-backed local ejection FIFO
// per node. Node index = y*MESH_X + x.
module mesh_4x4 #(
    parameter int MESSAGE_WIDTH = 128,
    parameter int FIFO_DEPTH    = 16
)(
    input  logic clk,
    input  logic rst,

    input  logic [MESH_X*MESH_Y*MESSAGE_WIDTH-1:0] tx_message_flat,
    input  logic [MESH_X*MESH_Y-1:0]               tx_valid_flat,
    output logic [MESH_X*MESH_Y-1:0]               tx_ready_flat,
    input  logic [MESH_X*MESH_Y*X_ADDR_WIDTH-1:0] tx_dest_x_flat,
    input  logic [MESH_X*MESH_Y*Y_ADDR_WIDTH-1:0] tx_dest_y_flat,

    output logic [MESH_X*MESH_Y*MESSAGE_WIDTH-1:0] rx_message_flat,
    output logic [MESH_X*MESH_Y-1:0]               rx_valid_flat,
    input  logic [MESH_X*MESH_Y-1:0]               rx_ready_flat,

    output logic                                      mesh_error
);

    localparam int NODES = MESH_X * MESH_Y;

    // NI signals.
    flit_t ni_inj_flit [0:NODES-1];
    logic  ni_inj_valid[0:NODES-1];
    logic  ni_inj_ready[0:NODES-1];
    flit_t ni_ej_flit  [0:NODES-1];
    logic  ni_ej_valid [0:NODES-1];
    logic  ni_ej_ready [0:NODES-1];
    logic  ni_error    [0:NODES-1];

    // Direction-level router signals keep topology wiring readable.
    flit_t r_in_flit    [0:NODES-1][0:NUM_PORTS-1];
    logic  r_in_valid   [0:NODES-1][0:NUM_PORTS-1];
    logic  r_in_ready   [0:NODES-1][0:NUM_PORTS-1];
    flit_t r_out_flit   [0:NODES-1][0:NUM_PORTS-1];
    logic  r_out_valid  [0:NODES-1][0:NUM_PORTS-1];
    logic  r_credit_in  [0:NODES-1][0:NUM_PORTS-1];
    logic  r_credit_out [0:NODES-1][0:NUM_PORTS-1];

    // Flattened adapters required by router.sv.
    logic [NUM_PORTS*FLIT_WIDTH-1:0] r_in_flat       [0:NODES-1];
    logic [NUM_PORTS-1:0]            r_in_valid_flat [0:NODES-1];
    logic [NUM_PORTS-1:0]            r_in_ready_flat [0:NODES-1];
    logic [NUM_PORTS*FLIT_WIDTH-1:0] r_out_flat      [0:NODES-1];
    logic [NUM_PORTS-1:0]            r_out_valid_flat[0:NODES-1];
    logic [NUM_PORTS-1:0]            r_credit_in_flat[0:NODES-1];
    logic [NUM_PORTS-1:0]            r_credit_out_flat[0:NODES-1];

    logic [FLIT_WIDTH-1:0] eject_head [0:NODES-1];
    logic                  eject_full [0:NODES-1];
    logic                  eject_empty[0:NODES-1];
    logic                  eject_wr_en[0:NODES-1];
    logic                  eject_rd_en[0:NODES-1];

    logic [NODES-1:0] ni_error_vec;
    logic [NODES-1:0] eject_overflow_vec;
    logic [NODES-1:0] boundary_error_vec;

    genvar n, p;
    generate
        for (n = 0; n < NODES; n++) begin : gen_node
            localparam int NODE_X = n % MESH_X;
            localparam int NODE_Y = n / MESH_X;

            network_interface #(
                .MESSAGE_WIDTH(MESSAGE_WIDTH)
            ) ni (
                .clk(clk),
                .rst(rst),
                .tx_message(tx_message_flat[n*MESSAGE_WIDTH +: MESSAGE_WIDTH]),
                .tx_valid(tx_valid_flat[n]),
                .tx_ready(tx_ready_flat[n]),
                .tx_dest_x(tx_dest_x_flat[n*X_ADDR_WIDTH +: X_ADDR_WIDTH]),
                .tx_dest_y(tx_dest_y_flat[n*Y_ADDR_WIDTH +: Y_ADDR_WIDTH]),
                .inj_flit(ni_inj_flit[n]),
                .inj_valid(ni_inj_valid[n]),
                .inj_ready(ni_inj_ready[n]),
                .ej_flit(ni_ej_flit[n]),
                .ej_valid(ni_ej_valid[n]),
                .ej_ready(ni_ej_ready[n]),
                .rx_message(rx_message_flat[n*MESSAGE_WIDTH +: MESSAGE_WIDTH]),
                .rx_valid(rx_valid_flat[n]),
                .rx_ready(rx_ready_flat[n]),
                .protocol_error(ni_error[n])
            );

            router #(
                .FIFO_DEPTH(FIFO_DEPTH),
                .CURRENT_X(X_ADDR_WIDTH'(NODE_X)),
                .CURRENT_Y(Y_ADDR_WIDTH'(NODE_Y))
            ) rtr (
                .clk(clk),
                .rst(rst),
                .flit_in_flat(r_in_flat[n]),
                .flit_valid_flat(r_in_valid_flat[n]),
                .flit_ready_flat(r_in_ready_flat[n]),
                .flit_out_flat(r_out_flat[n]),
                .flit_out_valid_flat(r_out_valid_flat[n]),
                .credit_in(r_credit_in_flat[n]),
                .credit_out(r_credit_out_flat[n])
            );

            // Pack and unpack each router direction independently.
            for (p = 0; p < NUM_PORTS; p++) begin : gen_port_adapter
                assign r_in_flat[n][p*FLIT_WIDTH +: FLIT_WIDTH] =
                    r_in_flit[n][p];
                assign r_in_valid_flat[n][p] = r_in_valid[n][p];
                assign r_in_ready[n][p] = r_in_ready_flat[n][p];

                assign r_out_flit[n][p] = flit_t'(
                    r_out_flat[n][p*FLIT_WIDTH +: FLIT_WIDTH]);
                assign r_out_valid[n][p] = r_out_valid_flat[n][p];

                assign r_credit_in_flat[n][p] = r_credit_in[n][p];
                assign r_credit_out[n][p] = r_credit_out_flat[n][p];
            end

            // Local injection: NI -> router LOCAL input.
            assign r_in_flit[n][DIR_LOCAL]  = ni_inj_flit[n];
            assign r_in_valid[n][DIR_LOCAL] = ni_inj_valid[n];
            assign ni_inj_ready[n]          = r_in_ready[n][DIR_LOCAL];

            // Local ejection: router LOCAL output -> credit-backed FIFO -> NI.
            fifo #(
                .WIDTH(FLIT_WIDTH),
                .DEPTH(FIFO_DEPTH)
            ) local_ejection_fifo (
                .clk(clk),
                .rst(rst),
                .wr_en(eject_wr_en[n]),
                .wr_data(r_out_flit[n][DIR_LOCAL]),
                .rd_en(eject_rd_en[n]),
                .rd_data(),
                .head_data(eject_head[n]),
                .full(eject_full[n]),
                .empty(eject_empty[n])
            );

            assign eject_wr_en[n] = r_out_valid[n][DIR_LOCAL];
            assign ni_ej_flit[n]  = flit_t'(eject_head[n]);
            assign ni_ej_valid[n] = !eject_empty[n];
            assign eject_rd_en[n] = ni_ej_valid[n] && ni_ej_ready[n];
            assign r_credit_in[n][DIR_LOCAL] = eject_rd_en[n];

            // EAST input comes from the WEST output of the eastern neighbor.
            if (NODE_X < MESH_X-1) begin : gen_east_neighbor
                localparam int EAST_NODE = n + 1;
                assign r_in_flit[n][DIR_EAST] =
                    r_out_flit[EAST_NODE][DIR_WEST];
                assign r_in_valid[n][DIR_EAST] =
                    r_out_valid[EAST_NODE][DIR_WEST];
                assign r_credit_in[n][DIR_EAST] =
                    r_credit_out[EAST_NODE][DIR_WEST];
            end
            else begin : gen_east_boundary
                assign r_in_flit[n][DIR_EAST] = '0;
                assign r_in_valid[n][DIR_EAST] = 1'b0;
                assign r_credit_in[n][DIR_EAST] = 1'b0;
            end

            // WEST input comes from the EAST output of the western neighbor.
            if (NODE_X > 0) begin : gen_west_neighbor
                localparam int WEST_NODE = n - 1;
                assign r_in_flit[n][DIR_WEST] =
                    r_out_flit[WEST_NODE][DIR_EAST];
                assign r_in_valid[n][DIR_WEST] =
                    r_out_valid[WEST_NODE][DIR_EAST];
                assign r_credit_in[n][DIR_WEST] =
                    r_credit_out[WEST_NODE][DIR_EAST];
            end
            else begin : gen_west_boundary
                assign r_in_flit[n][DIR_WEST] = '0;
                assign r_in_valid[n][DIR_WEST] = 1'b0;
                assign r_credit_in[n][DIR_WEST] = 1'b0;
            end

            // NORTH input comes from the SOUTH output of the northern neighbor.
            if (NODE_Y < MESH_Y-1) begin : gen_north_neighbor
                localparam int NORTH_NODE = n + MESH_X;
                assign r_in_flit[n][DIR_NORTH] =
                    r_out_flit[NORTH_NODE][DIR_SOUTH];
                assign r_in_valid[n][DIR_NORTH] =
                    r_out_valid[NORTH_NODE][DIR_SOUTH];
                assign r_credit_in[n][DIR_NORTH] =
                    r_credit_out[NORTH_NODE][DIR_SOUTH];
            end
            else begin : gen_north_boundary
                assign r_in_flit[n][DIR_NORTH] = '0;
                assign r_in_valid[n][DIR_NORTH] = 1'b0;
                assign r_credit_in[n][DIR_NORTH] = 1'b0;
            end

            // SOUTH input comes from the NORTH output of the southern neighbor.
            if (NODE_Y > 0) begin : gen_south_neighbor
                localparam int SOUTH_NODE = n - MESH_X;
                assign r_in_flit[n][DIR_SOUTH] =
                    r_out_flit[SOUTH_NODE][DIR_NORTH];
                assign r_in_valid[n][DIR_SOUTH] =
                    r_out_valid[SOUTH_NODE][DIR_NORTH];
                assign r_credit_in[n][DIR_SOUTH] =
                    r_credit_out[SOUTH_NODE][DIR_NORTH];
            end
            else begin : gen_south_boundary
                assign r_in_flit[n][DIR_SOUTH] = '0;
                assign r_in_valid[n][DIR_SOUTH] = 1'b0;
                assign r_credit_in[n][DIR_SOUTH] = 1'b0;
            end

            assign ni_error_vec[n] = ni_error[n];
            assign eject_overflow_vec[n] = eject_wr_en[n] && eject_full[n];
            assign boundary_error_vec[n] =
                ((NODE_X == 0)        && r_out_valid[n][DIR_WEST])  |
                ((NODE_X == MESH_X-1) && r_out_valid[n][DIR_EAST])  |
                ((NODE_Y == 0)        && r_out_valid[n][DIR_SOUTH]) |
                ((NODE_Y == MESH_Y-1) && r_out_valid[n][DIR_NORTH]);
        end
    endgenerate

    always_comb begin
        mesh_error = |ni_error_vec |
                     |eject_overflow_vec |
                     |boundary_error_vec;
    end

endmodule
