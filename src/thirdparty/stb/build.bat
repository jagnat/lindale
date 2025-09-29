@echo off

rem if not exist "..\lib" mkdir ..\lib

rem cl -nologo -MT -TC -O2 -c stb_image.c stb_image_write.c stb_image_resize.c stb_truetype.c stb_rect_pack.c stb_vorbis.c stb_sprintf.c
cl -nologo -MT -TC -Od -Z7 -DDEBUG -c stb_truetype.c
lib -nologo stb_truetype.obj -out:stb_truetype.lib

del *.obj
