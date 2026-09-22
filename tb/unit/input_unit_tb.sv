`timescale 1ns/1ps

import params_pkg::*;

module tb_input_unit;

    // ============================================================
    // Parameters
    // ============================================================

    localparam int FIFO_DEPTH = 4;


    // ============================================================
    // DUT signals
    // ============================================================

    logic       clk;
    logic       rst;

    flit_t      flit_in;
    logic       flit_valid;
    logic       flit_ready;

    // External Route Compute result
    direction_t route_in;
    logic       route_valid;

    // Switch Allocator interface
    logic [NUM_PORTS-1:0] request;
    logic                 grant;

    // Current FIFO head / flit toward crossbar
    flit_t      head_flit;


    // ============================================================
    // DUT
    // ============================================================

    input_unit #(
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk        (clk),
        .rst        (rst),

        .flit_in    (flit_in),
        .flit_valid (flit_valid),
        .flit_ready (flit_ready),

        .route_in    (route_in),
        .route_valid (route_valid),

        .request    (request),
        .grant      (grant),

        .head_flit  (head_flit)
    );


    // ============================================================
    // Clock generation
    // ============================================================

    initial begin
        clk = 1'b0;

        forever #5 clk = ~clk;
    end


    // ============================================================
    // Test variables
    // ============================================================

    int errors = 0;

    // head_flit is a combinational look-ahead of the FIFO's current
    // head (mem[rd_ptr]). rd_ptr advances on the same edge that
    // performs the read, so head_flit must be sampled BEFORE that
    // edge (i.e. right when grant is asserted), not after it.
    flit_t head_flit_snapshot;


    // ============================================================
    // Send flit task
    // ============================================================

    task automatic send_flit(
        input flit_type_t               flit_kind,
        input logic [X_ADDR_WIDTH-1:0]  dest_x,
        input logic [Y_ADDR_WIDTH-1:0]  dest_y,
        input logic [PAYLOAD_WIDTH-1:0] payload
    );

        begin

            @(negedge clk);

            flit_in.flit_type = flit_kind;
            flit_in.dest_x    = dest_x;
            flit_in.dest_y    = dest_y;
            flit_in.payload   = payload;

            flit_valid = 1'b1;

            wait (flit_ready);

            @(negedge clk);

            flit_valid = 1'b0;

        end

    endtask


    // ============================================================
    // Self-checking task
    // ============================================================

    task automatic check(
        input logic   condition,
        input string  message
    );

        begin

            if (condition) begin
                $display("[PASS] %s", message);
            end

            else begin
                $display("[FAIL] %s", message);
                errors++;
            end

        end

    endtask


    // ============================================================
    // Main test sequence
    // ============================================================

    initial begin

        // --------------------------------------------------------
        // Initial values
        // --------------------------------------------------------

        rst        = 1'b1;
        flit_valid = 1'b0;
        flit_in    = '0;
        route_in    = DIR_LOCAL;
        route_valid = 1'b0;
        grant       = 1'b0;


        // --------------------------------------------------------
        // Reset
        // --------------------------------------------------------

        repeat (2)
            @(posedge clk);

        rst = 1'b0;

        @(negedge clk);


        // ========================================================
        // TEST 1
        // FIFO should initially be empty and ready
        // ========================================================

        check(
            flit_ready == 1'b1,
            "FIFO is ready after reset"
        );

        check(
            request == '0,
            "No request while input unit is idle"
        );


        // ========================================================
        // TEST 2
        // Send one flit
        // ========================================================

        send_flit(
            FLIT_HEAD_TAIL,
            2'd3,
            2'd2,
            32'hAAAA_1111
        );

        $display("Flit injected");


        // External RC provides EAST route
        route_in    = DIR_EAST;
        route_valid = 1'b1;


        // ========================================================
        // Wait for ACTIVE state
        // ========================================================

        repeat (3)
            @(posedge clk);

        #1;


        // ========================================================
        // TEST 3
        // Correct EAST request
        // ========================================================

        check(
            request[DIR_EAST] == 1'b1,
            "EAST request generated"
        );

        check(
            request == (1'b1 << DIR_EAST),
            "Request is one-hot for EAST"
        );


        // ========================================================
        // TEST 4
        // No grant -> remain requesting
        // ========================================================

        grant = 1'b0;

        @(posedge clk);

        #1;

        check(
            request[DIR_EAST] == 1'b1,
            "Request remains active when grant is denied"
        );


        // ========================================================
        // TEST 5
        // Grant -> transfer
        // ========================================================

        grant = 1'b1;

        // Sample the head flit BEFORE the popping edge advances rd_ptr
        head_flit_snapshot = head_flit;

        @(posedge clk);

        #1;

        check(
            head_flit_snapshot.flit_type == FLIT_HEAD_TAIL,
            "Correct flit presented at output"
        );

        check(
            head_flit_snapshot.payload == 32'hAAAA_1111,
            "Correct payload presented at output"
        );


        // Remove grant
        @(negedge clk);

        grant       = 1'b0;
        route_valid = 1'b0;


        // ========================================================
        // TEST 6
        // FIFO should become empty
        // ========================================================

        @(posedge clk);

        #1;

        check(
            request == '0,
            "Request cleared after transfer"
        );

        check(
            flit_ready == 1'b1,
            "FIFO ready after transfer"
        );


        // ========================================================
        // TEST 7
        // Send second flit
        // ========================================================

        send_flit(
            FLIT_HEAD_TAIL,
            2'd1,
            2'd0,
            32'hBBBB_2222
        );

        // External RC provides NORTH route
        route_in    = DIR_NORTH;
        route_valid = 1'b1;


        // Wait for ACTIVE
        repeat (3)
            @(posedge clk);

        #1;


        check(
            request[DIR_NORTH] == 1'b1,
            "NORTH request generated"
        );


        // Grant second flit
        grant = 1'b1;

        head_flit_snapshot = head_flit;

        @(posedge clk);

        #1;

        check(
            head_flit_snapshot.payload == 32'hBBBB_2222,
            "Second flit transferred correctly"
        );


        @(negedge clk);

        grant       = 1'b0;
        route_valid = 1'b0;


        // ========================================================
        // TEST 8
        // Buffer multiple flits
        // ========================================================

        send_flit(
            FLIT_HEAD_TAIL,
            2'd0,
            2'd0,
            32'h1111_1111
        );

        send_flit(
            FLIT_HEAD_TAIL,
            2'd1,
            2'd1,
            32'h2222_2222
        );

        send_flit(
            FLIT_HEAD_TAIL,
            2'd2,
            2'd2,
            32'h3333_3333
        );

        $display("Multiple flits buffered");


        // ========================================================
        // TEST 9
        // First buffered flit
        // ========================================================

        route_in    = DIR_WEST;
        route_valid = 1'b1;

        repeat (3)
            @(posedge clk);

        #1;

        check(
            request[DIR_WEST] == 1'b1,
            "WEST request generated for first buffered flit"
        );

        grant = 1'b1;

        head_flit_snapshot = head_flit;

        @(posedge clk);

        #1;

        check(
            head_flit_snapshot.payload == 32'h1111_1111,
            "First buffered flit transferred"
        );


        @(negedge clk);

        grant       = 1'b0;
        route_valid = 1'b0;


        // ========================================================
        // TEST 10
        // Second buffered flit
        // ========================================================

        route_in    = DIR_SOUTH;
        route_valid = 1'b1;

        repeat (3)
            @(posedge clk);

        #1;

        check(
            request[DIR_SOUTH] == 1'b1,
            "SOUTH request generated for second buffered flit"
        );

        grant = 1'b1;

        head_flit_snapshot = head_flit;

        @(posedge clk);

        #1;

        check(
            head_flit_snapshot.payload == 32'h2222_2222,
            "Second buffered flit transferred"
        );


        @(negedge clk);

        grant       = 1'b0;
        route_valid = 1'b0;


        // ========================================================
        // TEST 11
        // Third buffered flit
        // ========================================================

        route_in    = DIR_EAST;
        route_valid = 1'b1;

        repeat (3)
            @(posedge clk);

        #1;

        check(
            request[DIR_EAST] == 1'b1,
            "EAST request generated for third buffered flit"
        );

        grant = 1'b1;

        head_flit_snapshot = head_flit;

        @(posedge clk);

        #1;

        check(
            head_flit_snapshot.payload == 32'h3333_3333,
            "Third buffered flit transferred"
        );


        @(negedge clk);

        grant       = 1'b0;
        route_valid = 1'b0;


        // ========================================================
        // Final result
        // ========================================================

        repeat (2)
            @(posedge clk);

        if (errors == 0) begin

            $display("");
            $display("========================================");
            $display("       ALL TESTS PASSED");
            $display("========================================");
            $display("");

        end

        else begin

            $display("");
            $display("========================================");
            $display("       TESTS FAILED: %0d", errors);
            $display("========================================");
            $display("");

        end

        $finish;

    end

endmodule