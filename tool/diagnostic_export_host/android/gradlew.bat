@echo off
rem Reuse the existing pinned wrapper launcher/JAR; isolate the project directory.
call "%~dp0..\..\..\android\gradlew.bat" -p "%~dp0." %*
exit /b %errorlevel%
