`timescale 1ns/1ps

module day23_stress_tb;
    import params_pkg::*;

    localparam int MESSAGE_WIDTH = 128;
    localparam int FIFO_DEPTH = 16;
    localparam int NODES = MESH_X*MESH_Y;
    localparam int TEST_CYCLES = 3000;
    localparam int DRAIN_TIMEOUT = 50000;
    localparam int MAX_PACKETS = 4096;
    localparam logic [7:0] INJECTION_THRESHOLD = 8'd24;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic traffic_enable;
    logic [NODES*MESSAGE_WIDTH-1:0] tx_message_flat;
    logic [NODES-1:0] tx_valid_flat, tx_ready_flat;
    logic [NODES*X_ADDR_WIDTH-1:0] tx_dest_x_flat;
    logic [NODES*Y_ADDR_WIDTH-1:0] tx_dest_y_flat;
    logic [NODES*MESSAGE_WIDTH-1:0] rx_message_flat;
    logic [NODES-1:0] rx_valid_flat, rx_ready_flat;
    logic mesh_error;

    logic [MESSAGE_WIDTH-1:0] tg_message [0:NODES-1];
    logic tg_valid [0:NODES-1];
    logic [X_ADDR_WIDTH-1:0] tg_dest_x [0:NODES-1];
    logic [Y_ADDR_WIDTH-1:0] tg_dest_y [0:NODES-1];
    logic [31:0] tg_count [0:NODES-1];

    logic [MESSAGE_WIDTH-1:0]
        expected_message [0:NODES-1][0:MAX_PACKETS-1];
    int expected_destination [0:NODES-1][0:MAX_PACKETS-1];
    int injection_cycle [0:NODES-1][0:MAX_PACKETS-1];
    logic expected_valid [0:NODES-1][0:MAX_PACKETS-1];
    logic received_flag [0:NODES-1][0:MAX_PACKETS-1];
    int last_seq_for_flow [0:NODES-1][0:NODES-1];

    int cycle_count;
    int accepted_count;
    int received_count;
    longint latency_sum;
    int min_latency, max_latency;
    logic progress_event;
    logic traffic_outstanding;
    logic watchdog_timeout;
    logic test_done = 1'b0;

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

    genvar n;
    generate
        for (n=0; n<NODES; n++) begin : gen_sources
            traffic_generator #(
                .MESSAGE_WIDTH(MESSAGE_WIDTH),
                .NODE_ID(n),
                .LFSR_SEED(16'h2101 + n*16'h31)
            ) source (
                .clk(clk), .rst(rst),
                .enable(traffic_enable),
                .injection_threshold(INJECTION_THRESHOLD),
                .fixed_dest_enable(1'b0),
                .fixed_dest_x('0), .fixed_dest_y('0),
                .tx_message(tg_message[n]),
                .tx_valid(tg_valid[n]),
                .tx_ready(tx_ready_flat[n]),
                .tx_dest_x(tg_dest_x[n]),
                .tx_dest_y(tg_dest_y[n]),
                .packets_accepted(tg_count[n])
            );

            assign tx_message_flat[n*MESSAGE_WIDTH +: MESSAGE_WIDTH] =
                tg_message[n];
            assign tx_valid_flat[n] = tg_valid[n];
            assign tx_dest_x_flat[n*X_ADDR_WIDTH +: X_ADDR_WIDTH] =
                tg_dest_x[n];
            assign tx_dest_y_flat[n*Y_ADDR_WIDTH +: Y_ADDR_WIDTH] =
                tg_dest_y[n];
        end
    endgenerate

    always_comb begin
        progress_event = |(tx_valid_flat & tx_ready_flat) |
                         |(rx_valid_flat & rx_ready_flat);
        for (int node=0; node<NODES; node++) begin
            for (int port_id=0; port_id<NUM_PORTS; port_id++)
                progress_event |= dut.r_out_valid[node][port_id];
        end

        traffic_outstanding = (accepted_count != received_count) ||
                              (tx_valid_flat != '0);
    end

    noc_watchdog #(.MAX_STALL_CYCLES(2000)) watchdog (
        .clk(clk), .rst(rst),
        .outstanding(traffic_outstanding),
        .progress_event(progress_event),
        .timeout(watchdog_timeout)
    );

    always @(posedge clk) begin : scoreboard
        logic [MESSAGE_WIDTH-1:0] message;
        int source_id, destination_id, seq_id, packet_latency;

        if (rst) begin
            cycle_count = 0;
            accepted_count = 0;
            received_count = 0;
            latency_sum = 0;
            min_latency = 32'h7fffffff;
            max_latency = 0;
            for (int s=0; s<NODES; s++) begin
                for (int d=0; d<NODES; d++)
                    last_seq_for_flow[s][d] = -1;
                for (int q=0; q<MAX_PACKETS; q++) begin
                    expected_valid[s][q] = 1'b0;
                    received_flag[s][q] = 1'b0;
                end
            end
        end else begin
            if (mesh_error)
                $fatal(1, "mesh_error at cycle %0d", cycle_count);
            if (watchdog_timeout)
                $fatal(1,
                    "WATCHDOG: no progress with traffic outstanding at cycle %0d",
                    cycle_count);

            for (int node=0; node<NODES; node++) begin
                if (tx_valid_flat[node] && tx_ready_flat[node]) begin
                    message = tx_message_flat[
                        node*MESSAGE_WIDTH +: MESSAGE_WIDTH];
                    source_id = int'(message[111:104]);
                    destination_id = int'(message[103:96]);
                    seq_id = int'(message[95:64]);

                    if (message[127:112] !== 16'hCAFE || source_id != node)
                        $fatal(1, "Bad injected message at node %0d", node);
                    if ((destination_id < 0) || (destination_id >= NODES))
                        $fatal(1, "Invalid destination %0d", destination_id);
                    if ((seq_id < 0) || (seq_id >= MAX_PACKETS))
                        $fatal(1, "Scoreboard capacity exceeded source=%0d", source_id);
                    if (expected_valid[source_id][seq_id])
                        $fatal(1, "Duplicate injected ID source=%0d seq=%0d",
                               source_id, seq_id);

                    expected_message[source_id][seq_id] = message;
                    expected_destination[source_id][seq_id] = destination_id;
                    injection_cycle[source_id][seq_id] = cycle_count;
                    expected_valid[source_id][seq_id] = 1'b1;
                    accepted_count++;
                end
            end

            for (int node=0; node<NODES; node++) begin
                if (rx_valid_flat[node] && rx_ready_flat[node]) begin
                    message = rx_message_flat[
                        node*MESSAGE_WIDTH +: MESSAGE_WIDTH];
                    source_id = int'(message[111:104]);
                    destination_id = int'(message[103:96]);
                    seq_id = int'(message[95:64]);

                    if (message[127:112] !== 16'hCAFE)
                        $fatal(1, "Payload corruption at node %0d", node);
                    if ((source_id < 0) || (source_id >= NODES) ||
                        (seq_id < 0) || (seq_id >= MAX_PACKETS))
                        $fatal(1, "Invalid received packet ID");
                    if (destination_id != node)
                        $fatal(1, "Misroute expected=%0d actual=%0d",
                               destination_id, node);
                    if (!expected_valid[source_id][seq_id])
                        $fatal(1, "Unexpected packet source=%0d seq=%0d",
                               source_id, seq_id);
                    if (received_flag[source_id][seq_id])
                        $fatal(1, "Duplicate packet source=%0d seq=%0d",
                               source_id, seq_id);
                    if (expected_destination[source_id][seq_id] != node ||
                        expected_message[source_id][seq_id] !== message)
                        $fatal(1, "Scoreboard mismatch source=%0d seq=%0d",
                               source_id, seq_id);
                    if (seq_id <= last_seq_for_flow[source_id][destination_id])
                        $fatal(1, "Per-flow reorder source=%0d dest=%0d seq=%0d",
                               source_id, destination_id, seq_id);

                    last_seq_for_flow[source_id][destination_id] = seq_id;
                    received_flag[source_id][seq_id] = 1'b1;
                    packet_latency = cycle_count -
                                     injection_cycle[source_id][seq_id];
                    latency_sum += packet_latency;
                    if (packet_latency < min_latency)
                        min_latency = packet_latency;
                    if (packet_latency > max_latency)
                        max_latency = packet_latency;
                    received_count++;
                end
            end

            cycle_count++;
        end
    end

    initial begin : stress_test
        int drain_cycles;
        real average_latency;
        real throughput;

        traffic_enable = 1'b0;
        rx_ready_flat = '1;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        traffic_enable = 1'b1;

        repeat (TEST_CYCLES) @(posedge clk);
        @(negedge clk);
        traffic_enable = 1'b0;

        drain_cycles = 0;
        while ((tx_valid_flat != '0) ||
               (received_count != accepted_count)) begin
            @(posedge clk);
            drain_cycles++;
            if (drain_cycles > DRAIN_TIMEOUT)
                $fatal(1, "Drain timeout accepted=%0d received=%0d",
                       accepted_count, received_count);
        end

        repeat (10) @(posedge clk);
        if (accepted_count == 0 || received_count != accepted_count)
            $fatal(1, "Packet conservation failure");

        average_latency = real'(latency_sum) / real'(received_count);
        throughput = real'(received_count*4) / real'(TEST_CYCLES);

        test_done = 1'b1;
        $display("PASS: Day 23 uniform-random contention stress completed");
        $display("  Injection threshold : %0d / 256", INJECTION_THRESHOLD);
        $display("  Accepted/received   : %0d / %0d",
                 accepted_count, received_count);
        $display("  Average latency     : %0.2f cycles", average_latency);
        $display("  Minimum latency     : %0d cycles", min_latency);
        $display("  Maximum latency     : %0d cycles", max_latency);
        $display("  Throughput          : %0.4f flits/cycle", throughput);
        $display("  Watchdog timeout    : %0d", watchdog_timeout);
        $finish;
    end
endmodule
