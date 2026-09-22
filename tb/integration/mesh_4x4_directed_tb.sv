`timescale 1ns/1ps

module mesh_4x4_tb;
    import params_pkg::*;

    localparam int MESSAGE_WIDTH  = 128;
    localparam int FIFO_DEPTH     = 16;
    localparam int NODES          = MESH_X * MESH_Y;
    localparam int NUM_FLITS      =
        (MESSAGE_WIDTH + PAYLOAD_WIDTH - 1) / PAYLOAD_WIDTH;
    localparam int TIMEOUT_CYCLES = 10000;

    localparam int SOURCE_NODE = 0;   // (0,0)
    localparam int DEST_NODE   = 15;  // (3,3)

    localparam logic [MESSAGE_WIDTH-1:0] TEST_MESSAGE =
        128'hDEADBEEF_CAFEF00D_01234567_89ABCDEF;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic [NODES*MESSAGE_WIDTH-1:0] tx_message_flat;
    logic [NODES-1:0]               tx_valid_flat;
    logic [NODES-1:0]               tx_ready_flat;
    logic [NODES*X_ADDR_WIDTH-1:0] tx_dest_x_flat;
    logic [NODES*Y_ADDR_WIDTH-1:0] tx_dest_y_flat;

    logic [NODES*MESSAGE_WIDTH-1:0] rx_message_flat;
    logic [NODES-1:0]               rx_valid_flat;
    logic [NODES-1:0]               rx_ready_flat;
    logic                           mesh_error;

    int cycle_count    = 0;
    int received_count = 0;
    int hop_flits [0:6];
    logic test_done = 1'b0;

    mesh_4x4 #(
        .MESSAGE_WIDTH(MESSAGE_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk(clk),
        .rst(rst),
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

    // Verify the expected route for node 0 (0,0) -> node 15 (3,3):
    // node 0 E, node 1 E, node 2 E, node 3 N, node 7 N,
    // node 11 N, node 15 LOCAL.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count    <= 0;
            received_count <= 0;
            for (int i = 0; i < 7; i++)
                hop_flits[i] <= 0;
        end
        else begin
            cycle_count <= cycle_count + 1;

            if (!test_done && (cycle_count > TIMEOUT_CYCLES))
                $fatal(1, "4x4 mesh timeout after %0d cycles", cycle_count);

            if (mesh_error)
                $fatal(1, "mesh_error asserted at time %0t", $time);

            if ($isunknown({tx_ready_flat, rx_valid_flat, mesh_error}))
                $fatal(1, "Unknown top-level control signal at time %0t",
                       $time);

            if (dut.r_out_valid[0][DIR_EAST])
                hop_flits[0] <= hop_flits[0] + 1;
            if (dut.r_out_valid[1][DIR_EAST])
                hop_flits[1] <= hop_flits[1] + 1;
            if (dut.r_out_valid[2][DIR_EAST])
                hop_flits[2] <= hop_flits[2] + 1;
            if (dut.r_out_valid[3][DIR_NORTH])
                hop_flits[3] <= hop_flits[3] + 1;
            if (dut.r_out_valid[7][DIR_NORTH])
                hop_flits[4] <= hop_flits[4] + 1;
            if (dut.r_out_valid[11][DIR_NORTH])
                hop_flits[5] <= hop_flits[5] + 1;
            if (dut.r_out_valid[15][DIR_LOCAL])
                hop_flits[6] <= hop_flits[6] + 1;

            // No endpoint other than node 15 may receive the packet.
            for (int node = 0; node < NODES; node++) begin
                if ((node != DEST_NODE) && rx_valid_flat[node])
                    $fatal(1, "Message ejected at wrong node %0d", node);
            end

            if (rx_valid_flat[DEST_NODE] && rx_ready_flat[DEST_NODE]) begin
                if (received_count != 0)
                    $fatal(1, "Destination received a duplicate message");

                if (rx_message_flat[
                        DEST_NODE*MESSAGE_WIDTH +: MESSAGE_WIDTH]
                    !== TEST_MESSAGE)
                    $fatal(1,
                        "Payload mismatch: expected=%h actual=%h",
                        TEST_MESSAGE,
                        rx_message_flat[
                            DEST_NODE*MESSAGE_WIDTH +: MESSAGE_WIDTH]);

                received_count <= received_count + 1;
            end
        end
    end

    initial begin : directed_test
        bit accepted;

        tx_message_flat = '0;
        tx_valid_flat   = '0;
        tx_dest_x_flat  = '0;
        tx_dest_y_flat  = '0;
        rx_ready_flat   = '1;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Inject one message at node 0 for node 15 at coordinate (3,3).
        @(negedge clk);
        tx_message_flat[
            SOURCE_NODE*MESSAGE_WIDTH +: MESSAGE_WIDTH] = TEST_MESSAGE;
        tx_dest_x_flat[
            SOURCE_NODE*X_ADDR_WIDTH +: X_ADDR_WIDTH] = X_ADDR_WIDTH'(3);
        tx_dest_y_flat[
            SOURCE_NODE*Y_ADDR_WIDTH +: Y_ADDR_WIDTH] = Y_ADDR_WIDTH'(3);
        tx_valid_flat[SOURCE_NODE] = 1'b1;

        accepted = 1'b0;
        while (!accepted) begin
            @(posedge clk);
            accepted = tx_ready_flat[SOURCE_NODE];
        end

        @(negedge clk);
        tx_valid_flat[SOURCE_NODE] = 1'b0;
        tx_message_flat[
            SOURCE_NODE*MESSAGE_WIDTH +: MESSAGE_WIDTH] = '0;

        wait (received_count == 1);
        repeat (10) @(posedge clk);

        for (int hop = 0; hop < 7; hop++) begin
            if (hop_flits[hop] != NUM_FLITS)
                $fatal(1,
                    "Hop %0d flit-count mismatch: expected=%0d actual=%0d",
                    hop, NUM_FLITS, hop_flits[hop]);
        end

        if (received_count != 1)
            $fatal(1, "Expected one received message, got %0d",
                   received_count);

        test_done = 1'b1;
        $display("PASS: 4x4 mesh delivered %0d-bit message node 0 (0,0) -> node 15 (3,3) over E,E,E,N,N,N with %0d intact flits.",
                 MESSAGE_WIDTH, NUM_FLITS);
        $finish;
    end

endmodule
