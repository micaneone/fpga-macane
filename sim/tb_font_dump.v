
`timescale 1ns/1ps
module tb_font_dump;
    reg clk = 0;
    always #12.5 clk = ~clk;
    reg  [4:0] ch = 5'd0;
    reg  [4:0] row = 5'd0;
    reg  [4:0] col = 5'd0;
    wire px;
    integer gy, c;
    font_cn u_font (.clk(clk), .ch(ch), .row(row), .col(col), .px(px));

    task probe(input [4:0] tch, input [4:0] trow, input [4:0] tcol, output p);
        begin
            ch = tch; row = trow; col = tcol;
            @(posedge clk); #1;
            p = px;
        end
    endtask

    integer fd;
    reg p;
    initial begin
        fd = $fopen("fontdump.txt", "w");
        for (gy = 0; gy < 24; gy = gy + 1) begin
            for (c = 0; c < 24; c = c + 1) begin
                probe(5'd10, 5'd23 - gy[4:0], c[4:0], p);
                $fwrite(fd, "%0d", p);
            end
            $fwrite(fd, "\n");
        end
        $fclose(fd);
        $display("DUMP DONE");
        $finish;
    end
endmodule
