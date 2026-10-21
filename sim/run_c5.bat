@echo off
REM ==== C5 regression: run all 9 offline benches, each in its own work lib ====
set MS=D:\altera\14.1\modelsim_ase\win32aloem
cd /d E:\FPGA\ygcom\pre-release-testing\sim

call :bench work_c5a tb_menu_font ..\b_display\font_rom.v ..\b_display\menu_ovl.v tb_menu_font.v
call :bench work_c5b tb_menu_cn ..\b_display\font_cn.v ..\b_display\menu_ovl_cn.v tb_menu_cn.v
call :bench work_c5c tb_bri_scale ..\b_display\bri_scale.v tb_bri_scale.v
call :bench work_c5d tb_transition ..\b_display\transition.v ..\b_display\transition_ctrl.v tb_transition.v
call :bench work_c5e tb_failsafe_pg ..\b_display\font_rom.v ..\b_display\failsafe_pg.v tb_failsafe_pg.v
call :bench work_c5f tb_bmp_decim ..\a_image\find_bmp.v ..\a_image\bmp_analyze.v tb_bmp_decim.v
call :bench work_c5g tb_find_name ..\a_image\find_bmp.v tb_find_name.v
call :bench work_c5h tb_sfx_player ..\a_image\sfx_player.v tb_sfx_player.v
call :bench work_c5i tb_sd_stream ..\a_image\sd_read.v ..\a_image\my_spi.v sd_card_model.v tb_sd_stream.v
echo ALL_DONE
goto :eof

:bench
set LIB=%1
set TB=%2
shift
shift
set SRC=
:loop
if "%~1"=="" goto endloop
set SRC=%SRC% %1
shift
goto loop
:endloop
if exist %LIB% rmdir /s /q %LIB%
"%MS%\vlib.exe" %LIB% >nul
"%MS%\vlog.exe" -quiet -work %LIB% %SRC% > "%LIB%.compile.log" 2>&1
if errorlevel 1 echo #### %TB% COMPILE_FAIL
"%MS%\vmap.exe" %LIB% %LIB% >nul
echo #### %TB%
"%MS%\vsim.exe" -c -quiet %LIB%.%TB% -do "run -all; quit -f" 2>&1
goto :eof
