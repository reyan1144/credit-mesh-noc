`timescale 1ns/1ps

module tb_fifo;

    parameter int WIDTH = 32;
    parameter int DEPTH = 4;

    logic             clk;
    logic             rst;

    logic             wr_en;
    logic [WIDTH-1:0] wr_data;

    logic             rd_en;
    logic [WIDTH-1:0] rd_data;

    logic             full;
    logic             empty;

    // DUT

    fifo #(
        .WIDTH(WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .clk     (clk),
        .rst     (rst),

        .wr_en   (wr_en),
        .wr_data (wr_data),

        .rd_en   (rd_en),
        .rd_data (rd_data),

        .full    (full),
        .empty   (empty)
    );


    // Clock

    always #5 clk = ~clk;

    // Test sequence

    initial begin

        // Initial values
        clk     = 1'b0;
        rst     = 1'b1;

        wr_en   = 1'b0;
        wr_data = '0;

        rd_en   = 1'b0;

        // Reset

        @(posedge clk);
        @(posedge clk);

        rst = 1'b0;

        // Check FIFO is empty after reset
        @(posedge clk);

        if (empty && !full)
            $display("PASS: FIFO is empty after reset");
        else
            $error("FAIL: FIFO reset status incorrect");

        // Write first value 

        @(posedge clk);

        wr_en   = 1'b1;
        wr_data = 32'h12345678;

        @(posedge clk);

        wr_en = 1'b0;

        // FIFO should no longer be empty
        if (!empty)
            $display("PASS: FIFO accepted first write");
        else
            $error("FAIL: FIFO still empty after write");

        // Read first value

        @(posedge clk);

        rd_en = 1'b1;

        @(posedge clk);

        rd_en = 1'b0;

        if (rd_data == 32'h12345678)
            $display("PASS: Read data = %h", rd_data);
        else
            $error("FAIL: Expected 12345678, got %h", rd_data);


        // FIFO should be empty again
        if (empty)
            $display("PASS: FIFO empty after read");
        else
            $error("FAIL: FIFO not empty after read");

        // Fill FIFO completely

        @(posedge clk);

        wr_en   = 1'b1;
        wr_data = 32'h11111111;

        @(posedge clk);

        wr_data = 32'h22222222;

        @(posedge clk);

        wr_data = 32'h33333333;

        @(posedge clk);

        wr_data = 32'h44444444;

        @(posedge clk);

        wr_en = 1'b0;


        // Check full
        if (full)
            $display("PASS: FIFO full after %0d writes", DEPTH);
        else
            $error("FAIL: FIFO should be full");

        // Read all values and check ordering 

        @(posedge clk);

        rd_en = 1'b1;

        @(posedge clk);

        if (rd_data == 32'h11111111)
            $display("PASS: FIFO order check 1");
        else
            $error("FAIL: Expected 11111111, got %h", rd_data);


        @(posedge clk);

        if (rd_data == 32'h22222222)
            $display("PASS: FIFO order check 2");
        else
            $error("FAIL: Expected 22222222, got %h", rd_data);


        @(posedge clk);

        if (rd_data == 32'h33333333)
            $display("PASS: FIFO order check 3");
        else
            $error("FAIL: Expected 33333333, got %h", rd_data);


        @(posedge clk);

        if (rd_data == 32'h44444444)
            $display("PASS: FIFO order check 4");
        else
            $error("FAIL: Expected 44444444, got %h", rd_data);


        rd_en = 1'b0;


        // FIFO should be empty
        @(posedge clk);

        if (empty)
            $display("PASS: FIFO empty after reading all entries");
        else
            $error("FAIL: FIFO should be empty");

        // Test pointer wrap-around

        @(posedge clk);

        wr_en   = 1'b1;
        wr_data = 32'hAAAA0001;

        @(posedge clk);

        wr_data = 32'hAAAA0002;

        @(posedge clk);

        wr_en = 1'b0;


        @(posedge clk);

        rd_en = 1'b1;

        @(posedge clk);

        if (rd_data == 32'hAAAA0001)
            $display("PASS: Wrap-around read 1");
        else
            $error("FAIL: Wrap-around expected AAAA0001, got %h", rd_data);


        @(posedge clk);

        if (rd_data == 32'hAAAA0002)
            $display("PASS: Wrap-around read 2");
        else
            $error("FAIL: Wrap-around expected AAAA0002, got %h", rd_data);


        rd_en = 1'b0;

        // End simulation

        @(posedge clk);

        $display("FIFO TEST COMPLETE");

        $finish;

    end

endmodule
