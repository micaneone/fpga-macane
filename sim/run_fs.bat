@echo off
REM ==== offline bench: failsafe_pg (D2 fallback page ASCII dump) ====
set MS=D:\altera\14.1\modelsim_ase\win32aloem
cd /d E:\FPGA\ygcom\pre-release-testing\sim
if exist work_fs rmdir /s /q work_fs
"%MS%\vlib.exe" work_fs
"%MS%\vlog.exe" -quiet -work work_fs ..\b_display\font_rom.v
"%MS%\vlog.exe" -quiet -work work_fs ..\b_display\failsafe_pg.v
"%MS%\vlog.exe" -quiet -work work_fs tb_failsafe_pg.v
"%MS%\vmap.exe" work_fs work_fs
"%MS%\vsim.exe" -c -quiet work_fs.tb_failsafe_pg -do "run -all; quit -f"
