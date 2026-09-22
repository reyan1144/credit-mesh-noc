`timescale 1ns/1ps

import params_pkg::*;

module route_compute_tb;

    // ============================================================
    // DUT Inputs
    // ============================================================

    logic [X_ADDR_WIDTH-1:0] current_x;
    logic [Y_ADDR_WIDTH-1:0] current_y;

    logic [X_ADDR_WIDTH-1:0] dest_x;
    logic [Y_ADDR_WIDTH-1:0] dest_y;

    direction_t direction;


    // ============================================================
    // DUT
    // ============================================================

    route_compute dut (
        .current_x (current_x),
        .current_y (current_y),
        .dest_x    (dest_x),
        .dest_y    (dest_y),
        .direction (direction)
    );


    // ============================================================
    // Test Task
    // ============================================================

    task automatic test_route (
        input logic [X_ADDR_WIDTH-1:0] cur_x,
        input logic [Y_ADDR_WIDTH-1:0] cur_y,
        input logic [X_ADDR_WIDTH-1:0] dst_x,
        input logic [Y_ADDR_WIDTH-1:0] dst_y,
        input direction_t expected
    );

        begin

            current_x = cur_x;
            current_y = cur_y;
            dest_x    = dst_x;
            dest_y    = dst_y;

            #1;

            if (direction == expected) begin

                $display(
                    "PASS: Current=(%0d,%0d) Dest=(%0d,%0d) Expected=%s Got=%s",
                    cur_x, cur_y,
                    dst_x, dst_y,
                    expected.name(),
                    direction.name()
                );

            end
            else begin

                $error(
                    "FAIL: Current=(%0d,%0d) Dest=(%0d,%0d) Expected=%s Got=%s",
                    cur_x, cur_y,
                    dst_x, dst_y,
                    expected.name(),
                    direction.name()
                );

            end

        end

    endtask


    // ============================================================
    // Test Sequence
    // ============================================================

    initial begin

        $display("==============================================");
        $display("       TinyNoC Route Compute Testbench");
        $display("==============================================");


        // --------------------------------------------------------
        // LOCAL
        // --------------------------------------------------------

        test_route(0, 0, 0, 0, DIR_LOCAL);
        test_route(1, 1, 1, 1, DIR_LOCAL);
        test_route(3, 3, 3, 3, DIR_LOCAL);


        // --------------------------------------------------------
        // EAST
        // --------------------------------------------------------

        test_route(0, 0, 1, 0, DIR_EAST);
        test_route(0, 0, 3, 0, DIR_EAST);
        test_route(1, 2, 3, 2, DIR_EAST);


        // --------------------------------------------------------
        // WEST
        // --------------------------------------------------------

        test_route(3, 0, 2, 0, DIR_WEST);
        test_route(3, 3, 0, 3, DIR_WEST);
        test_route(3, 2, 0, 2, DIR_WEST);


        // --------------------------------------------------------
        // NORTH
        // --------------------------------------------------------

        test_route(0, 0, 0, 1, DIR_NORTH);
        test_route(0, 0, 0, 3, DIR_NORTH);
        test_route(2, 1, 2, 3, DIR_NORTH);


        // --------------------------------------------------------
        // SOUTH
        // --------------------------------------------------------

        test_route(0, 3, 0, 2, DIR_SOUTH);
        test_route(3, 3, 3, 0, DIR_SOUTH);
        test_route(2, 2, 2, 0, DIR_SOUTH);


        // --------------------------------------------------------
        // DIAGONAL / XY PRIORITY TESTS
        // --------------------------------------------------------

        // X differs → EAST, even though Y also differs
        test_route(1, 1, 3, 3, DIR_EAST);

        // X differs → WEST, even though Y also differs
        test_route(3, 3, 1, 1, DIR_WEST);

        // X matches → NORTH
        test_route(1, 1, 1, 3, DIR_NORTH);

        // X matches → SOUTH
        test_route(2, 3, 2, 0, DIR_SOUTH);


        // --------------------------------------------------------
        // CORNER / BOUNDARY TESTS
        // --------------------------------------------------------

        // Bottom-left → top-right
        test_route(0, 0, 3, 3, DIR_EAST);

        // Top-right → bottom-left
        test_route(3, 3, 0, 0, DIR_WEST);

        // Bottom-left → top-left
        test_route(0, 0, 0, 3, DIR_NORTH);

        // Top-left → bottom-left
        test_route(0, 3, 0, 0, DIR_SOUTH);


        $display("==============================================");
        $display("       Route Compute Tests Completed");
        $display("==============================================");

        $finish;

    end

endmodule