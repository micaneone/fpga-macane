@echo off
REM ==== offline bench runner: bmp_analyze + find_bmp (名字匹配移植后回归) ====
set MS=D:\altera\14.1\modelsim_ase\win32aloem
cd /d E:\FPGA\ygcom\pre-release-testing\sim
if exist work_bd rmdir /s /q work_bd
"%MS%\vlib.exe" work_bd
"%MS%\vlog.exe" -quiet -work work_bd ..\a_image\find_bmp.v
"%MS%\vlog.exe" -quiet -work work_bd ..\a_image\bmp_analyze.v
"%MS%\vlog.exe" -quiet -work work_bd tb_bmp_decim.v
"%MS%\vmap.exe" work_bd work_bd
"%MS%\vsim.exe" -c -quiet work_bd.tb_bmp_decim -do "run -all; quit -f"
