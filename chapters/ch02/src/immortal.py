#!/usr/bin/python3
# 2章「シグナル」の intignore.py と同じ発想で、SIGINT と SIGTERM を無視する。
# SIGKILL と SIGSTOP は無視できない(2章コラム「絶対殺す SIGKILL」)。
import signal
import time

signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)

while True:
    time.sleep(60)
