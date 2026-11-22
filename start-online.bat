@echo off
title LocaShare Online Server (PHP + Cloudflare HTTPS Tunnel)
cd /d "%~dp0"

echo Starting LocaShare PHP Backend on http://127.0.0.1:8080 ...
start "LocaShare PHP Backend" /min "C:\xampp\php\php.exe" -S 0.0.0.0:8080 -t backend backend\router.php

timeout /t 2 /nobreak >nul

echo Starting Cloudflare Public HTTPS Tunnel ...
echo Copy the https://....trycloudflare.com URL below into your Android app and browser:
"C:\Program Files (x86)\cloudflared\cloudflared.exe" tunnel --url http://127.0.0.1:8080
