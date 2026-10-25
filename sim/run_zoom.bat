@echo off
rem ---- zoom pipe sim: new zoom_sel (3-stage) vs old zoom_sel_ref ----
set MS=D:\altera\14.1\modelsim_ase\win32aloem
cd /d E:\FPGA\ygcom\pre-release-testing\sim
if exist work_zoom rmdir /s /q work_zoom
"%MS%\vlib.exe" work_zoom
"%MS%\vlog.exe" -quiet -work work_zoom ..\b_display\zoom_sel.v zoom_sel_ref.v tb_zoom_pipe.v
"%MS%\vsim.exe" -c -quiet work_zoom.tb_zoom_pipe -do "run -all; quit -f"
