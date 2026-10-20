when {/tb_sd_stream/u_dut/flag_r == 4'd7} {echo "  STRM   %0t" $now}
when {/tb_sd_stream/u_dut/flag_r == 4'd8} {echo "  STRME  %0t" $now}
when {/tb_sd_stream/u_dut/flag_r == 4'd6} {echo "  STOP   %0t" $now}
when {/tb_sd_stream/u_dut/flag_r == 4'd3} {echo "  TOKEN  %0t" $now}
when {/tb_sd_stream/u_dut/flag_r == 4'd0} {echo "  IDLE   %0t" $now}
run 7ms
quit -f