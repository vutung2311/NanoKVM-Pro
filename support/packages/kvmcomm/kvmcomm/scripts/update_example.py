#!/usr/bin/env python3
import os
import sys
import time
import atexit
import subprocess
from pathlib import Path

def daemonize():
    if os.fork() > 0: 
        sys.exit(0)  # Parent exits
    os.setsid()
    if os.fork() > 0:
        sys.exit(0)
    os.umask(0o022)
    os.chdir('/')

def log_status(message):
    """记录状态到日志文件"""
    with open('/update-out.txt', 'a') as log:
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        log.write(f"[{timestamp}] {message}\n")

def launch_updater():
    """通过系统级临时文件启动更新进程"""
    update_script = '''#!/bin/sh
exec 9>/var/lock/kvmcomm.update
flock -x 9 || exit 1

# 记录初始状态
echo "=== Update started at $(date) ===" >> /update-out.txt
systemctl status kvmcomm.service >> /update-out.txt 2>&1

# 停止服务阶段
echo "Stopping service..." >> /update-out.txt
systemctl stop kvmcomm.service >> /update-out.txt 2>&1
echo "Stop command exit code: $?" >> /update-out.txt

timeout 10 systemctl stop kvmcomm.service || {
    echo "Force stopping service..." >> /update-out.txt
    systemctl kill kvmcomm.service >> /update-out.txt 2>&1
}
echo "Service stopped with status $?" >> /update-out.txt

# 安装阶段
echo "Installing package..." >> /update-out.txt
apt install /home/sipeed/kvmcomm*.deb >> /update-out.txt 2>&1
echo "Install completed with status $?" >> /update-out.txt

# 启动服务阶段
echo "Starting service..." >> /update-out.txt
systemctl start kvmcomm.service >> /update-out.txt 2>&1
echo "Start command exit code: $?" >> /update-out.txt

# 最终状态检查
systemctl status kvmcomm.service >> /update-out.txt 2>&1
echo "=== Update completed at $(date) ===" >> /update-out.txt

rm -f "$0"  # 自清理
'''
    with open('/usr/libexec/kvmcomm-update', 'w') as f:
        f.write(update_script)
    os.chmod('/usr/libexec/kvmcomm-update', 0o700)
    
    # 通过临时systemd单元执行
    subprocess.Popen([
        'systemd-run',
        '--unit=kvmcomm-update',
        '--scope',
        '--property=KillMode=process',  # 禁用systemd进程管理
        '--property=RuntimeMaxSec=30', # 限制最大运行时间 30s
        '/usr/libexec/kvmcomm-update'
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

if __name__ == '__main__':
    if '--update' in sys.argv:
        daemonize()
        launch_updater()
        sys.exit(0)

    # 主业务循环
    while True:
        try:
            # 检查更新标记文件
            if os.path.exists('/update-flag'):
                log_status("Update flag detected, initiating update process")
                os.remove('/update-flag')
                launch_updater()
            
            # 正常服务逻辑...
            
        except Exception as e:
            log_status(f"Main loop error: {str(e)}")
        
        time.sleep(3)
        # xxxxxxx
        # yyyyyyy
