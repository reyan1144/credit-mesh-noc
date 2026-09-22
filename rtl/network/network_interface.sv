`timescale 1ns/1ps

import params_pkg::*;

module network_interface #(
    parameter int MESSAGE_WIDTH = 128
)(
    input  logic                    clk,
    input  logic                    rst,

    // Endpoint -> NI message interface
    input  logic [MESSAGE_WIDTH-1:0] tx_message,
    input  logic                     tx_valid,
    output logic                     tx_ready,
    input  logic [X_ADDR_WIDTH-1:0]  tx_dest_x,
    input  logic [Y_ADDR_WIDTH-1:0]  tx_dest_y,

    // NI -> router LOCAL input (injection)
    output flit_t                    inj_flit,
    output logic                     inj_valid,
    input  logic                     inj_ready,

    // Router LOCAL output -> NI (ejection)
    input  flit_t                    ej_flit,
    input  logic                     ej_valid,
    output logic                     ej_ready,

    // NI -> endpoint reconstructed-message interface
    output logic [MESSAGE_WIDTH-1:0] rx_message,
    output logic                     rx_valid,
    input  logic                     rx_ready,

    // One-cycle pulse when an invalid fixed-length flit sequence is observed.
    output logic                     protocol_error
);

    localparam int NUM_FLITS =
        (MESSAGE_WIDTH + PAYLOAD_WIDTH - 1) / PAYLOAD_WIDTH;
    localparam int PADDED_WIDTH = NUM_FLITS * PAYLOAD_WIDTH;
    localparam int PAD_BITS = PADDED_WIDTH - MESSAGE_WIDTH;
    localparam int INDEX_WIDTH = (NUM_FLITS <= 1) ? 1 : $clog2(NUM_FLITS);

    // ================================================================
    // Transmit packetizer
    // ================================================================

    logic [PADDED_WIDTH-1:0] tx_shift_reg;
    logic [X_ADDR_WIDTH-1:0] tx_dest_x_reg;
    logic [Y_ADDR_WIDTH-1:0] tx_dest_y_reg;
    logic [INDEX_WIDTH-1:0]  tx_index;
    logic                    tx_active;

    assign tx_ready = !tx_active;
    assign inj_valid = tx_active;

    always_comb begin
        inj_flit = '0;
        inj_flit.dest_x  = tx_dest_x_reg;
        inj_flit.dest_y  = tx_dest_y_reg;
        inj_flit.payload = tx_shift_reg[PAYLOAD_WIDTH-1:0];

        if (NUM_FLITS == 1)
            inj_flit.flit_type = FLIT_HEAD_TAIL;
        else if (tx_index == 0)
            inj_flit.flit_type = FLIT_HEAD;
        else if (tx_index == NUM_FLITS-1)
            inj_flit.flit_type = FLIT_TAIL;
        else
            inj_flit.flit_type = FLIT_BODY;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_shift_reg <= '0;
            tx_dest_x_reg <= '0;
            tx_dest_y_reg <= '0;
            tx_index <= '0;
            tx_active <= 1'b0;
        end
        else begin
            // Capture a complete endpoint message only when idle.
            if (tx_valid && tx_ready) begin
                tx_shift_reg <= {{PAD_BITS{1'b0}}, tx_message};
                tx_dest_x_reg <= tx_dest_x;
                tx_dest_y_reg <= tx_dest_y;
                tx_index <= '0;
                tx_active <= 1'b1;
            end
            // Hold inj_flit stable under backpressure. Advance only on fire.
            else if (inj_valid && inj_ready) begin
                if (tx_index == NUM_FLITS-1) begin
                    tx_index <= '0;
                    tx_active <= 1'b0;
                end
                else begin
                    tx_shift_reg <= tx_shift_reg >> PAYLOAD_WIDTH;
                    tx_index <= tx_index + 1'b1;
                end
            end
        end
    end

    // Receive reassembler

    logic [PADDED_WIDTH-1:0] rx_assembly;
    logic [PADDED_WIDTH-1:0] rx_start_value;
    logic [PADDED_WIDTH-1:0] rx_insert_value;
    logic [INDEX_WIDTH-1:0]  rx_index;
    logic                    rx_in_packet;
    
    assign ej_ready = !rx_valid;

    always_comb begin
        // Used for HEAD/HEAD_TAIL: start from a clean padded message.
        rx_start_value = '0;
        rx_start_value[0 +: PAYLOAD_WIDTH] = ej_flit.payload;

        // Used for BODY/TAIL: insert at the current payload-word position.
        rx_insert_value = rx_assembly;
        rx_insert_value[rx_index*PAYLOAD_WIDTH +: PAYLOAD_WIDTH] =
            ej_flit.payload;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_assembly <= '0;
            rx_index <= '0;
            rx_in_packet <= 1'b0;
            rx_message <= '0;
            rx_valid <= 1'b0;
            protocol_error <= 1'b0;
        end
        else begin
            protocol_error <= 1'b0;

            // Hold rx_message and rx_valid until the endpoint accepts them.
            if (rx_valid && rx_ready)
                rx_valid <= 1'b0;

            if (ej_valid && ej_ready) begin
                if (!rx_in_packet) begin
                    case (ej_flit.flit_type)
                        FLIT_HEAD: begin
                            if (NUM_FLITS > 1) begin
                                rx_assembly <= rx_start_value;
                                rx_index <= INDEX_WIDTH'(1);
                                rx_in_packet <= 1'b1;
                            end
                            else begin
                                protocol_error <= 1'b1;
                                rx_assembly <= '0;
                                rx_index <= '0;
                            end
                        end

                        FLIT_HEAD_TAIL: begin
                            if (NUM_FLITS == 1) begin
                                rx_message <=
                                    rx_start_value[MESSAGE_WIDTH-1:0];
                                rx_valid <= 1'b1;
                            end
                            else begin
                                protocol_error <= 1'b1;
                            end
                            rx_assembly <= '0;
                            rx_index <= '0;
                            rx_in_packet <= 1'b0;
                        end

                        default: begin
                            // BODY or TAIL without an active packet.
                            protocol_error <= 1'b1;
                            rx_assembly <= '0;
                            rx_index <= '0;
                            rx_in_packet <= 1'b0;
                        end
                    endcase
                end
                else begin
                    case (ej_flit.flit_type)
                        FLIT_BODY: begin
                            // The final expected position must be a TAIL.
                            if (rx_index < NUM_FLITS-1) begin
                                rx_assembly <= rx_insert_value;
                                rx_index <= rx_index + 1'b1;
                            end
                            else begin
                                protocol_error <= 1'b1;
                                rx_assembly <= '0;
                                rx_index <= '0;
                                rx_in_packet <= 1'b0;
                            end
                        end

                        FLIT_TAIL: begin
                            if (rx_index == NUM_FLITS-1) begin
                                // rx_insert_value includes the current TAIL;
                                // using rx_assembly directly would lose it due
                                // to nonblocking-assignment timing.
                                rx_message <=
                                    rx_insert_value[MESSAGE_WIDTH-1:0];
                                rx_valid <= 1'b1;
                            end
                            else begin
                                protocol_error <= 1'b1;
                            end
                            rx_assembly <= '0;
                            rx_index <= '0;
                            rx_in_packet <= 1'b0;
                        end

                        default: begin
                            // A new HEAD/HEAD_TAIL cannot interrupt a packet.
                            protocol_error <= 1'b1;
                            rx_assembly <= '0;
                            rx_index <= '0;
                            rx_in_packet <= 1'b0;
                        end
                    endcase
                end
            end
        end
    end

    initial begin
        if (MESSAGE_WIDTH <= 0)
            $error("network_interface: MESSAGE_WIDTH must be positive");
        if (PAYLOAD_WIDTH <= 0)
            $error("network_interface: PAYLOAD_WIDTH must be positive");
    end

endmodule
