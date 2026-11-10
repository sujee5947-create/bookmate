@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo BOOKMATE AI 처리 서버를 시작합니다. 이 창을 닫으면 AI 처리가 멈춰요.
python bookmate_worker.py
pause
