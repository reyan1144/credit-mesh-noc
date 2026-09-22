`timescale 1ns/1ps

module noc_scoreboard_tb;
    import params_pkg::*;

    localparam int MESSAGE_WIDTH  = 128;
    localparam int FIFO_DEPTH     = 16;
    localparam int NODES          = MESH_X * MESH_Y;
    localparam int TOTAL_PACKETS  = 96;
    localparam int MAX_PER_SOURCE = TOTAL_PACKETS;
    localparam int TIMEOUT_CYCLES = 50000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic [NODES*MESSAGE_WIDTH-1:0] tx_message_flat;
    logic [NODES-1:0] tx_valid_flat, tx_ready_flat;
    logic [NODES*X_ADDR_WIDTH-1:0] tx_dest_x_flat;
    logic [NODES*Y_ADDR_WIDTH-1:0] tx_dest_y_flat;
    logic [NODES*MESSAGE_WIDTH-1:0] rx_message_flat;
    logic [NODES-1:0] rx_valid_flat, rx_ready_flat;
    logic mesh_error;

    logic [MESSAGE_WIDTH-1:0]
        expected_message [0:NODES-1][0:MAX_PER_SOURCE-1];
    int expected_destination [0:NODES-1][0:MAX_PER_SOURCE-1];
    int write_index [0:NODES-1];
    int read_index [0:NODES-1];
    int generated_count [0:NODES-1];

    logic [NUM_PORTS-1:0] direction_covered;
    logic [NODES-1:0] destination_covered;
    logic rx_backpressure_covered;
    logic ejection_full_covered;
    logic flow_covered [0:NODES-1][0:NODES-1];

    int cycle_count;
    int accepted_count;
    int received_count;
    int flow_coverage_count;
    int ready_phase;
    logic test_done = 1'b0;
    logic force_ready_low = 1'b0;
    logic [15:0] random_state = 16'hBEEF;

    mesh_4x4 #(
        .MESSAGE_WIDTH(MESSAGE_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk(clk), .rst(rst),
        .tx_message_flat(tx_message_flat),
        .tx_valid_flat(tx_valid_flat),
        .tx_ready_flat(tx_ready_flat),
        .tx_dest_x_flat(tx_dest_x_flat),
        .tx_dest_y_flat(tx_dest_y_flat),
        .rx_message_flat(rx_message_flat),
        .rx_valid_flat(rx_valid_flat),
        .rx_ready_flat(rx_ready_flat),
        .mesh_error(mesh_error)
    );

    function automatic logic [15:0]
        next_random(input logic [15:0] value);
        return {value[14:0],
                value[15] ^ value[13] ^ value[12] ^ value[10]};
    endfunction

    function automatic logic [MESSAGE_WIDTH-1:0] make_message(
        input int source_id,
        input int destination_id,
        input int sequence_id,
        input int tag,
        input logic [15:0] random_bits
    );
        logic [MESSAGE_WIDTH-1:0] value;
        value = '0;
        value[127:112] = 16'hD022;
        value[111:104] = 8'(source_id);
        value[103:96]  = 8'(destination_id);
        value[95:64]   = 32'(sequence_id);
        value[63:32]   = 32'(tag);
        value[31:0]    = {random_bits, random_bits ^ 16'hA55A};
        return value;
    endfunction

    task automatic send_message(
        input int source_id,
        input int destination_id,
        input int tag
    );
        logic [MESSAGE_WIDTH-1:0] message;
        bit accepted;
        int wait_cycles;

        random_state = next_random(random_state);
        message = make_message(source_id, destination_id,
                               generated_count[source_id], tag,
                               random_state);

        @(negedge clk);
        tx_message_flat[source_id*MESSAGE_WIDTH +: MESSAGE_WIDTH] = message;
        tx_dest_x_flat[source_id*X_ADDR_WIDTH +: X_ADDR_WIDTH] =
            X_ADDR_WIDTH'(destination_id % MESH_X);
        tx_dest_y_flat[source_id*Y_ADDR_WIDTH +: Y_ADDR_WIDTH] =
            Y_ADDR_WIDTH'(destination_id / MESH_X);
        tx_valid_flat[source_id] = 1'b1;

        accepted = 1'b0;
        wait_cycles = 0;
        while (!accepted) begin
            @(posedge clk);
            accepted = tx_ready_flat[source_id];
            wait_cycles++;
            if (wait_cycles > TIMEOUT_CYCLES)
                $fatal(1, "Source %0d transmit timeout", source_id);
        end

        @(negedge clk);
        tx_valid_flat[source_id] = 1'b0;
        tx_message_flat[source_id*MESSAGE_WIDTH +: MESSAGE_WIDTH] = '0;
        generated_count[source_id]++;
    endtask

    // Apply deterministic endpoint backpressure.
    always @(negedge clk) begin
        if (rst) begin
            ready_phase = 0;
            rx_ready_flat = '1;
        end else begin
            ready_phase = (ready_phase + 1) % 4;
            if (force_ready_low)
                rx_ready_flat = '0;
            else if (ready_phase == 0)
                rx_ready_flat = '0;
            else
                rx_ready_flat = '1;
        end
    end

    // Guarantee at least one observed receive stall.
    initial begin : force_one_stall
        wait (!rst);
        wait (|rx_valid_flat);
        force_ready_low = 1'b1;
        repeat (3) @(negedge clk);
        force_ready_low = 1'b0;
    end

    always @(posedge clk) begin : scoreboard
        logic [MESSAGE_WIDTH-1:0] message;
        int source_id;
        int destination_id;
        int sequence_id;

        if (rst) begin
            cycle_count = 0;
            accepted_count = 0;
            received_count = 0;
            direction_covered = '0;
            destination_covered = '0;
            rx_backpressure_covered = 1'b0;
            ejection_full_covered = 1'b0;

            for (int s = 0; s < NODES; s++) begin
                write_index[s] = 0;
                read_index[s] = 0;
                generated_count[s] = 0;
                for (int d = 0; d < NODES; d++)
                    flow_covered[s][d] = 1'b0;
            end
        end else begin
            if (!test_done && cycle_count > TIMEOUT_CYCLES)
                $fatal(1, "Timeout: accepted=%0d received=%0d",
                       accepted_count, received_count);

            if (mesh_error)
                $fatal(1, "mesh_error at cycle %0d", cycle_count);

            if ($isunknown({tx_ready_flat, rx_valid_flat, mesh_error}))
                $fatal(1, "Unknown top-level control at cycle %0d",
                       cycle_count);

            for (int node = 0; node < NODES; node++) begin
                if (tx_valid_flat[node] && tx_ready_flat[node]) begin
                    message = tx_message_flat[
                        node*MESSAGE_WIDTH +: MESSAGE_WIDTH];
                    source_id = int'(message[111:104]);
                    destination_id = int'(message[103:96]);
                    sequence_id = int'(message[95:64]);

                    if (message[127:112] !== 16'hD022)
                        $fatal(1, "Bad magic at source %0d", node);
                    if (source_id != node)
                        $fatal(1, "Source-field mismatch at node %0d", node);
                    if ((destination_id < 0) || (destination_id >= NODES))
                        $fatal(1, "Invalid destination %0d", destination_id);
                    if (sequence_id != write_index[source_id])
                        $fatal(1,
                            "Injection order error source=%0d expected=%0d actual=%0d",
                            source_id, write_index[source_id], sequence_id);
                    if (write_index[source_id] >= MAX_PER_SOURCE)
                        $fatal(1, "Expected queue overflow for source %0d",
                               source_id);

                    expected_message[source_id][write_index[source_id]] =
                        message;
                    expected_destination[source_id][write_index[source_id]] =
                        destination_id;
                    write_index[source_id]++;
                    accepted_count++;
                    flow_covered[source_id][destination_id] = 1'b1;
                end
            end

            for (int node = 0; node < NODES; node++) begin
                if (rx_valid_flat[node] && !rx_ready_flat[node])
                    rx_backpressure_covered = 1'b1;

                if (rx_valid_flat[node] && rx_ready_flat[node]) begin
                    message = rx_message_flat[
                        node*MESSAGE_WIDTH +: MESSAGE_WIDTH];
                    source_id = int'(message[111:104]);
                    destination_id = int'(message[103:96]);
                    sequence_id = int'(message[95:64]);

                    if (message[127:112] !== 16'hD022)
                        $fatal(1, "Corrupt magic at destination %0d", node);
                    if ((source_id < 0) || (source_id >= NODES))
                        $fatal(1, "Invalid received source %0d", source_id);
                    if (destination_id != node)
                        $fatal(1,
                            "Misroute: message destination=%0d ejected=%0d",
                            destination_id, node);
                    if (read_index[source_id] >= write_index[source_id])
                        $fatal(1,
                            "Unexpected/duplicate packet source=%0d seq=%0d",
                            source_id, sequence_id);
                    if (sequence_id != read_index[source_id])
                        $fatal(1,
                            "Reorder/drop source=%0d expected=%0d actual=%0d",
                            source_id, read_index[source_id], sequence_id);
                    if (expected_destination[source_id][read_index[source_id]]
                        != node)
                        $fatal(1, "Scoreboard destination mismatch");
                    if (message !==
                        expected_message[source_id][read_index[source_id]])
                        $fatal(1,
                            "Payload corruption source=%0d seq=%0d",
                            source_id, sequence_id);

                    read_index[source_id]++;
                    received_count++;
                    destination_covered[node] = 1'b1;
                end
            end

            for (int node = 0; node < NODES; node++) begin
                for (int direction_id = 0;
                     direction_id < NUM_PORTS; direction_id++) begin
                    if (dut.r_out_valid[node][direction_id])
                        direction_covered[direction_id] = 1'b1;
                end
                if (dut.eject_full[node])
                    ejection_full_covered = 1'b1;
            end

            cycle_count++;
        end
    end

    genvar a;
    generate
        for (a = 0; a < NODES; a++) begin : gen_assertions
            valid_ready_assertions #(
                .DATA_WIDTH(MESSAGE_WIDTH + X_ADDR_WIDTH + Y_ADDR_WIDTH)
            ) tx_protocol (
                .clk(clk), .rst(rst),
                .valid(tx_valid_flat[a]),
                .ready(tx_ready_flat[a]),
                .data({tx_message_flat[a*MESSAGE_WIDTH +: MESSAGE_WIDTH],
                       tx_dest_x_flat[a*X_ADDR_WIDTH +: X_ADDR_WIDTH],
                       tx_dest_y_flat[a*Y_ADDR_WIDTH +: Y_ADDR_WIDTH]})
            );

            valid_ready_assertions #(
                .DATA_WIDTH(MESSAGE_WIDTH)
            ) rx_protocol (
                .clk(clk), .rst(rst),
                .valid(rx_valid_flat[a]),
                .ready(rx_ready_flat[a]),
                .data(rx_message_flat[a*MESSAGE_WIDTH +: MESSAGE_WIDTH])
            );

            fifo_assertions eject_fifo_protocol (
                .clk(clk), .rst(rst),
                .wr_en(dut.eject_wr_en[a]),
                .rd_en(dut.eject_rd_en[a]),
                .full(dut.eject_full[a]),
                .empty(dut.eject_empty[a])
            );
        end
    endgenerate

    initial begin : randomized_test
        int source_id;
        int destination_id;
        int target_received;

        tx_message_flat = '0;
        tx_valid_flat = '0;
        tx_dest_x_flat = '0;
        tx_dest_y_flat = '0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        send_message(0, 3, 0);    // EAST
        wait (received_count == 1);
        send_message(3, 0, 1);    // WEST
        wait (received_count == 2);
        send_message(0, 12, 2);   // NORTH
        wait (received_count == 3);
        send_message(12, 0, 3);   // SOUTH
        wait (received_count == 4);
        send_message(5, 5, 4);    // LOCAL
        wait (received_count == 5);

        for (int packet_id = 5;
             packet_id < TOTAL_PACKETS; packet_id++) begin
            random_state = next_random(random_state);
            source_id = int'(random_state[3:0]);
            destination_id = (packet_id - 5) % NODES;

            if (((packet_id & 3) != 0) &&
                (source_id == destination_id))
                source_id = (source_id + 1) % NODES;

            target_received = received_count + 1;
            send_message(source_id, destination_id, packet_id);
            wait (received_count == target_received);
        end

        repeat (10) @(posedge clk);

        if ((accepted_count != TOTAL_PACKETS) ||
            (received_count != TOTAL_PACKETS))
            $fatal(1,
                "Conservation failure accepted=%0d received=%0d expected=%0d",
                accepted_count, received_count, TOTAL_PACKETS);

        for (int s = 0; s < NODES; s++) begin
            if (write_index[s] != read_index[s])
                $fatal(1,
                    "Outstanding source %0d written=%0d read=%0d",
                    s, write_index[s], read_index[s]);
        end

        if (direction_covered !== {NUM_PORTS{1'b1}})
            $fatal(1, "Incomplete direction coverage: %b",
                   direction_covered);
        if (destination_covered !== {NODES{1'b1}})
            $fatal(1, "Incomplete destination coverage: %h",
                   destination_covered);
        if (!rx_backpressure_covered)
            $fatal(1, "Receive backpressure was not exercised");

        flow_coverage_count = 0;
        for (int s = 0; s < NODES; s++)
            for (int d = 0; d < NODES; d++)
                if (flow_covered[s][d])
                    flow_coverage_count++;

        test_done = 1'b1;
        $display("PASS: Day 22 randomized scoreboard test completed");
        $display("  Accepted/received packets : %0d/%0d",
                 accepted_count, received_count);
        $display("  Directions covered        : %b (L,N,S,E,W)",
                 direction_covered);
        $display("  Destinations covered      : %h",
                 destination_covered);
        $display("  Unique flows covered      : %0d / %0d",
                 flow_coverage_count, NODES*NODES);
        $display("  Receive backpressure hit  : %0d",
                 rx_backpressure_covered);
        $display("  Ejection FIFO full hit    : %0d (not required)",
                 ejection_full_covered);
        $finish;
    end
endmodule
