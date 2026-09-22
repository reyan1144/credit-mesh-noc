`timescale 1ns/1ps

module tb_rr_arbiter;

    localparam int N = 4;

    logic         clk;
    logic         rst;
    logic [N-1:0] req;
    logic [N-1:0] grant;

    logic [$clog2(N)-1:0] saved_ptr;

    //==================================================
    // DUT
    //==================================================

    rr_arbiter #(
        .N(N)
    ) dut (
        .clk   (clk),
        .rst   (rst),
        .req   (req),
        .grant (grant)
    );

    //==================================================
    // Clock generation
    //==================================================

    always #5 clk = ~clk;

    //==================================================
    // SVA Assertions
    //==================================================

    // Grant must be one-hot-or-zero
    assert property (@(posedge clk) $onehot0(grant))
        else $error("SVA FAIL: Grant is not one-hot-or-zero");

    // Grant must correspond to an active request
    assert property (@(posedge clk) (grant & ~req) == '0)
        else $error("SVA FAIL: Grant issued without request");

    //==================================================
    // Test sequence
    //==================================================

    initial begin

        clk = 1'b0;
        rst = 1'b1;
        req = '0;

        //==================================================
        // Reset
        //==================================================

        repeat (2) @(posedge clk);

        rst = 1'b0;

        //==================================================
        // Test 1: No requests
        //==================================================

        #1;

        if (grant !== 4'b0000)
            $error("FAIL: No request, but grant = %b", grant);
        else
            $display("PASS: No request -> grant = %b", grant);

        //==================================================
        // Test 2: Single requester
        //==================================================

        req = 4'b0100;
        #1;

        if (grant !== 4'b0100)
            $error("FAIL: Single requester, grant = %b", grant);
        else
            $display("PASS: Single requester -> grant = %b", grant);

        //==================================================
        // Test 3: Round-robin rotation
        //==================================================

        req = 4'b1111;

        // RR step 1
        #1;

        if (grant !== 4'b0001)
            $error("FAIL: RR step 1, grant = %b", grant);
        else
            $display("PASS: RR step 1 -> grant = %b", grant);

        @(posedge clk);
        #1;

        // RR step 2
        if (grant !== 4'b0010)
            $error("FAIL: RR step 2, grant = %b", grant);
        else
            $display("PASS: RR step 2 -> grant = %b", grant);

        @(posedge clk);
        #1;

        // RR step 3
        if (grant !== 4'b0100)
            $error("FAIL: RR step 3, grant = %b", grant);
        else
            $display("PASS: RR step 3 -> grant = %b", grant);

        @(posedge clk);
        #1;

        // RR step 4
        if (grant !== 4'b1000)
            $error("FAIL: RR step 4, grant = %b", grant);
        else
            $display("PASS: RR step 4 -> grant = %b", grant);

        @(posedge clk);
        #1;

        // RR wrap-around
        if (grant !== 4'b0001)
            $error("FAIL: RR wrap-around, grant = %b", grant);
        else
            $display("PASS: RR wrap-around -> grant = %b", grant);

        //==================================================
        // Test 4: Skip inactive requesters
        //==================================================

        rst = 1'b1;

        @(posedge clk);

        rst = 1'b0;
        req = 4'b1010;

        // First arbitration
        #1;

        if (grant !== 4'b0010)
            $error("FAIL: Skip test step 1, grant = %b", grant);
        else
            $display("PASS: Skip test step 1 -> grant = %b", grant);

        @(posedge clk);
        #1;

        // Second arbitration
        if (grant !== 4'b1000)
            $error("FAIL: Skip test step 2, grant = %b", grant);
        else
            $display("PASS: Skip test step 2 -> grant = %b", grant);

        //==================================================
        // Test 5: Priority pointer holds with no requests
        //==================================================

        saved_ptr = dut.priority_ptr;

        req = 4'b0000;

        @(posedge clk);
        #1;

        if (grant !== 4'b0000)
            $error("FAIL: Pointer hold test, grant = %b", grant);
        else if (dut.priority_ptr !== saved_ptr)
            $error("FAIL: Priority pointer changed with no request");
        else
            $display("PASS: Priority pointer holds with no request");

        //==================================================
        // Test 6: Dynamic request pattern
        //==================================================

        req = 4'b0101;

        #1;

        if (grant !== 4'b0100)
            $error("FAIL: Dynamic test step 1, grant = %b", grant);
        else
            $display("PASS: Dynamic test step 1 -> grant = %b", grant);

        @(posedge clk);
        #1;

        req = 4'b1001;

        #1;

        if (grant !== 4'b1000)
            $error("FAIL: Dynamic test step 2, grant = %b", grant);
        else
            $display("PASS: Dynamic test step 2 -> grant = %b", grant);

        //==================================================
        // End simulation
        //==================================================

        $display("========================================");
        $display("ALL ROUND-ROBIN TESTS COMPLETED");
        $display("========================================");

        $finish;

    end

endmodule