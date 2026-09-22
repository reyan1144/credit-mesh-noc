`timescale 1ns/1ps

module network_interface_tb;
    import params_pkg::*;

    localparam int MESSAGE_WIDTH  = 128;
    localparam int NUM_MESSAGES   = 8;
    localparam int NUM_FLITS      =
        (MESSAGE_WIDTH + PAYLOAD_WIDTH - 1) / PAYLOAD_WIDTH;
    localparam int TOTAL_FLITS    = NUM_MESSAGES * NUM_FLITS;
    localparam int TIMEOUT_CYCLES = 3000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    // Endpoint transmit interface
    logic [MESSAGE_WIDTH-1:0] tx_message;
    logic                     tx_valid;
    wire                      tx_ready;
    logic [X_ADDR_WIDTH-1:0]  tx_dest_x;
    logic [Y_ADDR_WIDTH-1:0]  tx_dest_y;

    // Injection interface
    flit_t inj_flit;
    logic  inj_valid;
    logic  inj_ready;

    // Ejection interface
    flit_t ej_flit;
    logic  ej_valid;
    logic  ej_ready;

    // Endpoint receive interface
    logic [MESSAGE_WIDTH-1:0] rx_message;
    logic                     rx_valid;
    logic                     rx_ready;
    logic                     protocol_error;

    logic [MESSAGE_WIDTH-1:0] expected_message [0:NUM_MESSAGES-1];
    logic [X_ADDR_WIDTH-1:0]  expected_dest_x  [0:NUM_MESSAGES-1];
    logic [Y_ADDR_WIDTH-1:0]  expected_dest_y  [0:NUM_MESSAGES-1];

    int cycle_count       = 0;
    int accepted_messages = 0;
    int link_flits        = 0;
    int link_packet       = 0;
    int link_flit_index   = 0;
    int received_messages = 0;

    logic link_enable;
    logic force_rx_stall;
    logic hold_active;
    logic [MESSAGE_WIDTH-1:0] held_rx_message;
    logic inj_hold_active;
    flit_t held_inj_flit;

    network_interface #(
        .MESSAGE_WIDTH(MESSAGE_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),

        .tx_message(tx_message),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_dest_x(tx_dest_x),
        .tx_dest_y(tx_dest_y),

        .inj_flit(inj_flit),
        .inj_valid(inj_valid),
        .inj_ready(inj_ready),

        .ej_flit(ej_flit),
        .ej_valid(ej_valid),
        .ej_ready(ej_ready),

        .rx_message(rx_message),
        .rx_valid(rx_valid),
        .rx_ready(rx_ready),

        .protocol_error(protocol_error)
    );

    // Loop the packetizer back into the reassembler. link_enable inserts
    // deterministic router-side backpressure. rx_ready adds endpoint-side
    // backpressure after a complete message has been reconstructed.
    always_comb begin
        link_enable = ((cycle_count % 5) != 1) &&
                      ((cycle_count % 7) != 3);

        inj_ready = link_enable && ej_ready;
        ej_flit   = inj_flit;
        ej_valid  = inj_valid && link_enable;

        rx_ready = !force_rx_stall && ((cycle_count % 4) != 2);
    end

    function automatic logic [MESSAGE_WIDTH-1:0]
        make_message(input int message_id);
        logic [MESSAGE_WIDTH-1:0] value;
        value = '0;
        // Distinct 32-bit words make ordering errors easy to identify.
        for (int word_id = 0; word_id < NUM_FLITS; word_id++) begin
            value[word_id*PAYLOAD_WIDTH +: PAYLOAD_WIDTH] =
                PAYLOAD_WIDTH'((message_id << 16) |
                               (word_id << 8) |
                               (8'hA0 + message_id));
        end
        return value;
    endfunction

    function automatic flit_type_t
        expected_type(input int flit_id);
        if (NUM_FLITS == 1)
            return FLIT_HEAD_TAIL;
        else if (flit_id == 0)
            return FLIT_HEAD;
        else if (flit_id == NUM_FLITS-1)
            return FLIT_TAIL;
        else
            return FLIT_BODY;
    endfunction

    function automatic logic [PAYLOAD_WIDTH-1:0]
        expected_payload(input int packet_id, input int flit_id);
        return expected_message[packet_id]
            [flit_id*PAYLOAD_WIDTH +: PAYLOAD_WIDTH];
    endfunction

    // Hold a message and its destination stable until the NI accepts it.
    task automatic send_message(input int message_id);
        int wait_cycles;
        bit accepted;

        wait_cycles = 0;
        accepted = 0;

        @(negedge clk);
        tx_message = expected_message[message_id];
        tx_dest_x  = expected_dest_x[message_id];
        tx_dest_y  = expected_dest_y[message_id];
        tx_valid   = 1'b1;

        while (!accepted) begin
            @(posedge clk);
            accepted = tx_ready;
            wait_cycles++;
            if (wait_cycles > TIMEOUT_CYCLES)
                $fatal(1, "Transmit-message handshake timeout");
        end

        @(negedge clk);
        tx_valid   = 1'b0;
        tx_message = '0;
        tx_dest_x  = '0;
        tx_dest_y  = '0;
    endtask

    // Scoreboard and protocol checks.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count       <= 0;
            accepted_messages <= 0;
            link_flits        <= 0;
            link_packet       <= 0;
            link_flit_index   <= 0;
            received_messages <= 0;
            hold_active       <= 1'b0;
            held_rx_message   <= '0;
            inj_hold_active   <= 1'b0;
            held_inj_flit     <= '0;
        end
        else begin
            cycle_count <= cycle_count + 1;

            if (cycle_count > TIMEOUT_CYCLES)
                $fatal(1,
                    "Timeout: accepted=%0d link_flits=%0d received=%0d",
                    accepted_messages, link_flits, received_messages);

            if (protocol_error)
                $fatal(1, "Unexpected NI protocol_error at time %0t", $time);

            if ($isunknown({tx_ready, inj_valid, inj_ready,
                            ej_valid, ej_ready, rx_valid}))
                $fatal(1, "Unknown handshake signal at time %0t", $time);

            if (tx_valid && tx_ready)
                accepted_messages <= accepted_messages + 1;

            // The packetizer must hold the complete flit stable while the
            // router applies backpressure.
            if (inj_valid && !inj_ready) begin
                if (inj_hold_active && (inj_flit !== held_inj_flit))
                    $fatal(1, "inj_flit changed while inj_valid was stalled");
                held_inj_flit <= inj_flit;
                inj_hold_active <= 1'b1;
            end
            else begin
                inj_hold_active <= 1'b0;
            end

            // Check every actual loopback transfer.
            if (inj_valid && inj_ready) begin
                if (link_packet >= NUM_MESSAGES)
                    $fatal(1, "NI generated too many packets");

                if (inj_flit.flit_type !==
                    expected_type(link_flit_index))
                    $fatal(1,
                        "Wrong flit type: packet=%0d flit=%0d expected=%0d actual=%0d",
                        link_packet, link_flit_index,
                        expected_type(link_flit_index), inj_flit.flit_type);

                if (inj_flit.payload !==
                    expected_payload(link_packet, link_flit_index))
                    $fatal(1,
                        "Wrong payload: packet=%0d flit=%0d expected=%h actual=%h",
                        link_packet, link_flit_index,
                        expected_payload(link_packet, link_flit_index),
                        inj_flit.payload);

                if ((inj_flit.dest_x !== expected_dest_x[link_packet]) ||
                    (inj_flit.dest_y !== expected_dest_y[link_packet]))
                    $fatal(1,
                        "Wrong destination: packet=%0d expected=(%0d,%0d) actual=(%0d,%0d)",
                        link_packet,
                        expected_dest_x[link_packet],
                        expected_dest_y[link_packet],
                        inj_flit.dest_x, inj_flit.dest_y);

                link_flits <= link_flits + 1;
                if (link_flit_index == NUM_FLITS-1) begin
                    link_flit_index <= 0;
                    link_packet <= link_packet + 1;
                end
                else begin
                    link_flit_index <= link_flit_index + 1;
                end
            end

            // Verify that a completed message remains stable under endpoint
            // backpressure and compare it when the endpoint accepts it.
            if (rx_valid && !rx_ready) begin
                if (hold_active && (rx_message !== held_rx_message))
                    $fatal(1, "rx_message changed while rx_valid was stalled");
                held_rx_message <= rx_message;
                hold_active <= 1'b1;
            end
            else begin
                hold_active <= 1'b0;
            end

            if (rx_valid && rx_ready) begin
                if (received_messages >= NUM_MESSAGES)
                    $fatal(1, "Received too many messages");
                if (rx_message !== expected_message[received_messages])
                    $fatal(1,
                        "Reassembly mismatch: message=%0d expected=%h actual=%h",
                        received_messages,
                        expected_message[received_messages], rx_message);
                received_messages <= received_messages + 1;
            end
        end
    end

    // Force a longer endpoint stall on the first completed message. This also
    // propagates backpressure through the reassembler to the packetizer.
    initial begin : long_stall
        force_rx_stall = 1'b0;
        wait (!rst);
        wait (rx_valid);
        force_rx_stall = 1'b1;
        repeat (8) @(posedge clk);
        @(negedge clk);
        force_rx_stall = 1'b0;
    end

    initial begin : test_sequence
        tx_message = '0;
        tx_valid   = 1'b0;
        tx_dest_x  = '0;
        tx_dest_y  = '0;

        for (int i = 0; i < NUM_MESSAGES; i++) begin
            expected_message[i] = make_message(i);
            expected_dest_x[i]  = X_ADDR_WIDTH'((i + 1) % MESH_X);
            expected_dest_y[i]  = Y_ADDR_WIDTH'((i + 2) % MESH_Y);
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (int i = 0; i < NUM_MESSAGES; i++)
            send_message(i);

        wait (received_messages == NUM_MESSAGES);
        repeat (8) @(posedge clk);

        if (accepted_messages != NUM_MESSAGES)
            $fatal(1, "Accepted-message count mismatch: %0d",
                   accepted_messages);
        if (link_flits != TOTAL_FLITS)
            $fatal(1, "Flit count mismatch: expected=%0d actual=%0d",
                   TOTAL_FLITS, link_flits);
        if (link_packet != NUM_MESSAGES)
            $fatal(1, "Packet count mismatch: %0d", link_packet);
        if (received_messages != NUM_MESSAGES)
            $fatal(1, "Receive-message count mismatch: %0d",
                   received_messages);

        $display("PASS: NI packetized and reassembled %0d messages (%0d flits) with injection and endpoint backpressure.",
                 NUM_MESSAGES, TOTAL_FLITS);
        $finish;
    end

endmodule
