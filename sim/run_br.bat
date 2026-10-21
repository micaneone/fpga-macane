@echo off
set MS=D:\altera\14.1\modelsim_ase\win32aloem
cd /d E:\FPGA\ygcom\pre-release-testing\sim
if exist work_br rmdir /s /q work_br
"%MS%\vlib.exe" work_br
"%MS%\vlog.exe" -quiet -work work_br ..\b_display\bri_scale.v tb_bri_scale.v
"%MS%\vmap.exe" work_br work_br
"%MS%\vsim.exe" -c -quiet work_br.tb_bri_scale -do "run -all; quit -f"