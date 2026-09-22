`timescale 1ns/1ps

module packet_lock_tb;
    import params_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic [NUM_PORTS*NUM_PORTS-1:0] request_flat;
    logic [NUM_PORTS*FLIT_TYPE_WIDTH-1:0] flit_type_flat;
    logic [NUM_PORTS*NUM_PORTS-1:0] grant_flat;

    switch_alloc dut (
        .clk(clk),
        .rst(rst),
        .request_flat(request_flat),
        .flit_type_flat(flit_type_flat),
        .grant_flat(grant_flat)
    );

    task automatic set_type(input int input_id, input flit_type_t kind);
        flit_type_flat[input_id*FLIT_TYPE_WIDTH +: FLIT_TYPE_WIDTH] = kind;
    endtask

    task automatic expect_winner(input int expected_input,
                                 input string label_text);
        logic [NUM_PORTS-1:0] grants_for_east;
        #1;
        grants_for_east =
            grant_flat[DIR_EAST*NUM_PORTS +: NUM_PORTS];
        if (!$onehot(grants_for_east))
            $fatal(1, "%s: expected one grant, got %b",
                   label_text, grants_for_east);
        if (!grants_for_east[expected_input])
            $fatal(1, "%s: expected input %0d, got %b",
                   label_text, expected_input, grants_for_east);
        @(posedge clk);
        @(negedge clk);
    endtask

    initial begin
        request_flat = '0;
        flit_type_flat = '0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Inputs 0 and 1 both want EAST. Input 0 initially wins by RR.
        request_flat[0*NUM_PORTS + DIR_EAST] = 1'b1;
        request_flat[1*NUM_PORTS + DIR_EAST] = 1'b1;
        set_type(0, FLIT_HEAD);
        set_type(1, FLIT_HEAD);
        expect_winner(0, "packet A HEAD");

        // Even though B keeps requesting, A must retain the output.
        set_type(0, FLIT_BODY);
        expect_winner(0, "packet A BODY");

        set_type(0, FLIT_TAIL);
        expect_winner(0, "packet A TAIL");

        // A has ended. B can now acquire and retain the output.
        request_flat[0*NUM_PORTS + DIR_EAST] = 1'b0;
        set_type(1, FLIT_HEAD);
        expect_winner(1, "packet B HEAD");

        set_type(1, FLIT_BODY);
        expect_winner(1, "packet B BODY");

        set_type(1, FLIT_TAIL);
        expect_winner(1, "packet B TAIL");

        request_flat = '0;
        #1;
        if (grant_flat != '0)
            $fatal(1, "Grant remained active with no requests");

        $display("PASS: packet lock kept HEAD/BODY/TAIL contiguous for both contenders");
        $finish;
    end
endmodule
