@echo off
REM ==== offline bench runner: find_bmp_eng 名字分类找图 ====
set MS=D:\altera\14.1\modelsim_ase\win32aloem
cd /d E:\FPGA\ygcom\pre-release-testing\sim
if exist work_fn rmdir /s /q work_fn
"%MS%\vlib.exe" work_fn
"%MS%\vlog.exe" -quiet -work work_fn ..\a_image\find_bmp.v
"%MS%\vlog.exe" -quiet -work work_fn tb_find_name.v
"%MS%\vmap.exe" work_fn work_fn
"%MS%\vsim.exe" -c -quiet work_fn.tb_find_name -do "run -all; quit -f"
