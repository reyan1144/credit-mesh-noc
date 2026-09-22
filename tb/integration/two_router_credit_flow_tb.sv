`timescale 1ns/1ps

module two_router_chain_tb;
    import params_pkg::*;

    localparam int FIFO_DEPTH     = 16;
    localparam int NUM_PACKETS    = 12;
    localparam int FLITS_PER_PKT  = 3;
    localparam int TOTAL_FLITS    = NUM_PACKETS * FLITS_PER_PKT;
    localparam int TIMEOUT_CYCLES = 5000;

    localparam logic [X_ADDR_WIDTH-1:0] R0_X = X_ADDR_WIDTH'(0);
    localparam logic [Y_ADDR_WIDTH-1:0] R0_Y = Y_ADDR_WIDTH'(0);
    localparam logic [X_ADDR_WIDTH-1:0] R1_X = X_ADDR_WIDTH'(1);
    localparam logic [Y_ADDR_WIDTH-1:0] R1_Y = Y_ADDR_WIDTH'(0);

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    // Router 0 ports
    logic [NUM_PORTS*FLIT_WIDTH-1:0] r0_flit_in;
    logic [NUM_PORTS-1:0]            r0_flit_in_valid;
    wire  [NUM_PORTS-1:0]            r0_flit_in_ready;
    wire  [NUM_PORTS*FLIT_WIDTH-1:0] r0_flit_out;
    wire  [NUM_PORTS-1:0]            r0_flit_out_valid;
    logic [NUM_PORTS-1:0]            r0_credit_in;
    wire  [NUM_PORTS-1:0]            r0_credit_out;

    // Router 1 ports
    logic [NUM_PORTS*FLIT_WIDTH-1:0] r1_flit_in;
    logic [NUM_PORTS-1:0]            r1_flit_in_valid;
    wire  [NUM_PORTS-1:0]            r1_flit_in_ready;
    wire  [NUM_PORTS*FLIT_WIDTH-1:0] r1_flit_out;
    wire  [NUM_PORTS-1:0]            r1_flit_out_valid;
    logic [NUM_PORTS-1:0]            r1_credit_in;
    wire  [NUM_PORTS-1:0]            r1_credit_out;

    flit_t expected [0:TOTAL_FLITS-1];
    int accepted_count = 0;
    int link_count     = 0;
    int received_count = 0;
    int cycle_count    = 0;

    router #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .CURRENT_X(R0_X),
        .CURRENT_Y(R0_Y)
    ) router_0 (
        .clk(clk),
        .rst(rst),
        .flit_in_flat(r0_flit_in),
        .flit_valid_flat(r0_flit_in_valid),
        .flit_ready_flat(r0_flit_in_ready),
        .flit_out_flat(r0_flit_out),
        .flit_out_valid_flat(r0_flit_out_valid),
        .credit_in(r0_credit_in),
        .credit_out(r0_credit_out)
    );

    router #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .CURRENT_X(R1_X),
        .CURRENT_Y(R1_Y)
    ) router_1 (
        .clk(clk),
        .rst(rst),
        .flit_in_flat(r1_flit_in),
        .flit_valid_flat(r1_flit_in_valid),
        .flit_ready_flat(r1_flit_in_ready),
        .flit_out_flat(r1_flit_out),
        .flit_out_valid_flat(r1_flit_out_valid),
        .credit_in(r1_credit_in),
        .credit_out(r1_credit_out)
    );

    // Unidirectional physical link:
    // router_0 EAST output -> router_1 WEST input.
    // The reverse credit goes from router_1 WEST input buffer to
    // router_0 EAST output credit counter.
    always_comb begin
        r1_flit_in       = '0;
        r1_flit_in_valid = '0;
        r1_flit_in[DIR_WEST*FLIT_WIDTH +: FLIT_WIDTH] =
            r0_flit_out[DIR_EAST*FLIT_WIDTH +: FLIT_WIDTH];
        r1_flit_in_valid[DIR_WEST] = r0_flit_out_valid[DIR_EAST];

        r0_credit_in = '0;
        r0_credit_in[DIR_EAST] = r1_credit_out[DIR_WEST];

        // Model an always-consuming endpoint at router_1 LOCAL output.
        // Return its output credit one cycle after each valid flit.
        r1_credit_in = '0;
        r1_credit_in[DIR_LOCAL] = r1_flit_out_valid[DIR_LOCAL];
    end

    function automatic flit_t make_flit(
        input flit_type_t kind,
        input int packet_id,
        input int flit_id
    );
        flit_t value;
        value = '0;
        value.flit_type = kind;
        value.dest_x    = R1_X;
        value.dest_y    = R1_Y;
        value.payload   = PAYLOAD_WIDTH'((packet_id << 8) | flit_id);
        return value;
    endfunction

    // Drive one flit into router_0's LOCAL input and hold valid until ready.
    task automatic send_local(input flit_t value);
        int wait_cycles;
        bit accepted;

        wait_cycles = 0;
        accepted = 0;
        @(negedge clk);
        r0_flit_in[DIR_LOCAL*FLIT_WIDTH +: FLIT_WIDTH] = value;
        r0_flit_in_valid[DIR_LOCAL] = 1'b1;

        while (!accepted) begin
            @(posedge clk);
            accepted = r0_flit_in_ready[DIR_LOCAL];
            wait_cycles++;
            if (wait_cycles > TIMEOUT_CYCLES)
                $fatal(1, "Source handshake timeout");
        end

        @(negedge clk);
        r0_flit_in_valid[DIR_LOCAL] = 1'b0;
        r0_flit_in[DIR_LOCAL*FLIT_WIDTH +: FLIT_WIDTH] = '0;
    endtask

    // Self-checking scoreboard and link checks.
    always @(posedge clk) begin
        flit_t actual;

        if (rst) begin
            accepted_count <= 0;
            link_count     <= 0;
            received_count <= 0;
            cycle_count    <= 0;
        end
        else begin
            cycle_count <= cycle_count + 1;

            if (r0_flit_in_valid[DIR_LOCAL] &&
                r0_flit_in_ready[DIR_LOCAL]) begin
                if (accepted_count >= TOTAL_FLITS)
                    $fatal(1, "Accepted too many source flits");
                expected[accepted_count] = flit_t'(
                    r0_flit_in[DIR_LOCAL*FLIT_WIDTH +: FLIT_WIDTH]);
                accepted_count <= accepted_count + 1;
            end

            // This is the actual router_0 -> router_1 transfer edge.
            if (r0_flit_out_valid[DIR_EAST]) begin
                if (!r1_flit_in_ready[DIR_WEST])
                    $fatal(1, "Credit/ready mismatch: router_1 WEST FIFO full");
                if ($isunknown(r0_flit_out[DIR_EAST*FLIT_WIDTH +: FLIT_WIDTH]))
                    $fatal(1, "Unknown flit on inter-router link");
                link_count <= link_count + 1;
            end

            // No packet in this test may leave through an unintended port.
            for (int p = 0; p < NUM_PORTS; p++) begin
                if ((p != DIR_EAST) && r0_flit_out_valid[p])
                    $fatal(1, "router_0 used wrong output port %0d", p);
                if ((p != DIR_LOCAL) && r1_flit_out_valid[p])
                    $fatal(1, "router_1 used wrong output port %0d", p);
            end

            // router outputs are registered, so inspect new output after NBA.
            #1;
            if (r1_flit_out_valid[DIR_LOCAL]) begin
                if (received_count >= accepted_count)
                    $fatal(1, "Destination received an unexpected flit");

                actual = flit_t'(
                    r1_flit_out[DIR_LOCAL*FLIT_WIDTH +: FLIT_WIDTH]);

                if ($isunknown(actual))
                    $fatal(1, "Unknown flit at destination");

                if (actual !== expected[received_count])
                    $fatal(1,
                        "Data/order mismatch index=%0d expected=%h actual=%h",
                        received_count, expected[received_count], actual);

                received_count <= received_count + 1;
            end

            if (cycle_count > TIMEOUT_CYCLES)
                $fatal(1,
                    "Global timeout: accepted=%0d link=%0d received=%0d",
                    accepted_count, link_count, received_count);
        end
    end

    initial begin : test_sequence
        flit_t value;

        r0_flit_in       = '0;
        r0_flit_in_valid = '0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Send 12 three-flit packets. This exceeds FIFO_DEPTH overall and
        // therefore exercises repeated inter-router credit return.
        for (int packet = 0; packet < NUM_PACKETS; packet++) begin
            value = make_flit(FLIT_HEAD, packet, 0);
            send_local(value);

            value = make_flit(FLIT_BODY, packet, 1);
            send_local(value);

            value = make_flit(FLIT_TAIL, packet, 2);
            send_local(value);
        end

        wait (received_count == TOTAL_FLITS);
        repeat (10) @(posedge clk);

        if (accepted_count != TOTAL_FLITS)
            $fatal(1, "Not all source flits were accepted");
        if (link_count != TOTAL_FLITS)
            $fatal(1, "Inter-router link count mismatch: %0d", link_count);
        if (received_count != TOTAL_FLITS)
            $fatal(1, "Destination count mismatch: %0d", received_count);

        $display("PASS: %0d packets / %0d flits crossed router_0 EAST -> router_1 WEST and exited LOCAL in order.",
                 NUM_PACKETS, TOTAL_FLITS);
        $finish;
    end

endmodule
