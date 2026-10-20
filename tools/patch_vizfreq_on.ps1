$ErrorActionPreference = 'Stop'
$p   = 'E:\FPGA\ygcom\pre-release-testing\rtl\disp_top.v'
$enc = New-Object System.Text.UTF8Encoding($false)
$txt = [IO.File]::ReadAllText($p, $enc)
$nl  = if ($txt.Contains("`r`n")) { "`r`n" } else { "`n" }

$old1 = "wire        viz_freq_mask = 1'b0, viz_freq_band = 1'b0;"
$new1 = "wire        viz_freq_mask, viz_freq_band;"
$old2 = "wire [23:0] viz_freq_color = 24'd0;"
$new2 = "wire [23:0] viz_freq_color;"
$anchor = "    wire        viz_m   = viz_hist_mask | viz_freq_mask;"

$c1 = ([regex]::Matches($txt, [regex]::Escape($old1))).Count
$c2 = ([regex]::Matches($txt, [regex]::Escape($old2))).Count
$c3 = ([regex]::Matches($txt, [regex]::Escape($anchor))).Count
"counts: old1=$c1 old2=$c2 anchor=$c3"
if ($c1 -ne 1 -or $c2 -ne 1 -or $c3 -ne 1) { throw "anchor mismatch, abort" }

$block = @(
'    // ---- 2026-10-18: freq layer re-enabled (viz_freq v3 = time-multiplexed) ----',
'    //   params copied from viz2/viz_top.v u_freq / u_freq_draw:',
'    //   N=24, SMP_WIN=2048, LOG_BIAS=16 ; 24 bars x 8px at x16..208, y312..376',
'    //   To disable again: tie viz_freq_mask / viz_freq_band to 1''b0 and',
'    //   viz_freq_color to 24''d0 (the instances below get optimised away).',
'    wire        viz_fw_en;',
'    wire [4:0]  viz_fw_addr;',
'    wire [5:0]  viz_fw_val;',
'    wire [15:0] viz_fwin;',
'    wire        viz_fdump;',
'    wire [5:0]  viz_fhi;',
'',
'    viz_freq #(',
'        .N        (24),',
'        .SMP_WIN  (2048),',
'        .LOG_BIAS (16)',
'    ) u_viz_freq (',
'        .clk_aud   (clk_aud),',
'        .rst_aud_n (rst_aud_n),',
'        .aud_vld   (aud_viz_vld),',
'        .aud_dout  (aud_viz_dout),',
'        .aud_next  (aud_viz_next),',
'        .wr_en     (viz_fw_en),',
'        .wr_addr   (viz_fw_addr),',
'        .wr_val    (viz_fw_val),',
'        .dbg_win   (viz_fwin),',
'        .dbg_dump  (viz_fdump),',
'        .dbg_hi    (viz_fhi)',
'    );',
'',
'    viz_render #(',
'        .N          (24),',
'        .CELL_SHIFT (3),',
'        .VIS_X      (10''d16),',
'        .VIS_Y      (10''d312),',
'        .BAR_H      (10''d64),',
'        .DECAY_DIV  (48761),',
'        .PEAK_SLOW  (4''d4),',
'        .GAP        (1),',
'        .COL_B      (8''d24)',
'    ) u_viz_freq_draw (',
'        .clk_aud   (clk_aud),',
'        .rst_aud_n (rst_aud_n),',
'        .wr_en     (viz_fw_en),',
'        .wr_addr   (viz_fw_addr),',
'        .wr_val    (viz_fw_val),',
'        .de        (de_mix),',
'        .x         (o_dbg_x[9:0]),',
'        .y         (o_dbg_y[9:0]),',
'        .mask      (viz_freq_mask),',
'        .in_band   (viz_freq_band),',
'        .color     (viz_freq_color)',
'    );',
''
) -join $nl

$txt = $txt.Replace($old1, $new1).Replace($old2, $new2).Replace($anchor, $block + $anchor)
[IO.File]::WriteAllText($p, $txt, $enc)

$b = [IO.File]::ReadAllBytes($p)
"new len = $($b.Length)  first4 = $($b[0..3] -join ',')"
$chk = [IO.File]::ReadAllText($p, $enc)
$n1 = ($chk -split 'u_viz_freq_draw').Count - 1
$n2 = ($chk -split 'viz_freq_mask = ').Count - 1
"u_viz_freq_draw hits = $n1 ; leftover tie-off hits = $n2"
