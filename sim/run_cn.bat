@echo off
set MS=D:\altera\14.1\modelsim_ase\win32aloem
cd /d E:\FPGA\ygcom\pre-release-testing\sim
copy /y ..\b_display\font_cn.dat font_cn.dat >nul 2>&1
if exist work_cn rmdir /s /q work_cn
"%MS%\vlib.exe" work_cn
"%MS%\vlog.exe" -quiet -work work_cn eg_phy_bram32k_behav.v ..\b_display\font_cn.v ..\b_display\menu_ovl_cn.v tb_menu_cn.v
"%MS%\vmap.exe" work_cn work_cn
"%MS%\vsim.exe" -c -quiet work_cn.tb_menu_cn -do "run -all; quit -f"
