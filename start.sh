#!/bin/sh
# today-tasks 启动器（macOS / Linux）
# 如果提示 Permission denied，先跑一次：chmod +x start.sh
cd "$(dirname "$0")" || exit 1

if command -v python3 >/dev/null 2>&1; then
  exec python3 server.py
elif command -v python >/dev/null 2>&1; then
  exec python server.py
else
  echo "找不到 Python 3.8+。装一个再回来：https://www.python.org/downloads/"
  exit 1
fi
