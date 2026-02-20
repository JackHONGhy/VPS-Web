#!/bin/bash

# 检查权限
[[ $EUID -ne 0 ]] && echo "Error: 请使用 root 权限运行" && exit 1

echo "--- 正在启动 [生产级] 硬件感知自适应调优系统 ---"

# 1. 硬件数据采集
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)
# 修复版本号判断 Bug: 提取主次版本号
KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)

# 2. 核心逻辑：分级策略配置
# 默认值
SWAPPINESS=30
SOMAXCONN=1024
FILE_LIMIT=65535
BACKLOG=2048

if [ "$TOTAL_MEM" -lt 512 ]; then
    echo "状态: [微型机] 策略 - 优先保命 (避免OOM)"
    SWAPPINESS=80   # 极小内存下，宁可慢点用Swap，也别让进程挂掉
    SOMAXCONN=512
    BACKLOG=1024
elif [ "$TOTAL_MEM" -lt 1024 ]; then
    echo "状态: [轻量机] 策略 - 平衡型"
    SWAPPINESS=40
    SOMAXCONN=2048
    BACKLOG=4096
elif [ "$TOTAL_MEM" -lt 4096 ]; then
    echo "状态: [标准机] 策略 - 高性能"
    SWAPPINESS=20
    SOMAXCONN=8192
    BACKLOG=16384
else
    echo "状态: [大型生产级] 策略 - 极致吞吐"
    SWAPPINESS=10
    SOMAXCONN=65535
    BACKLOG=32768
    FILE_LIMIT=1048576
fi

# 3. 构造 sysctl 配置文件
cat > /etc/sysctl.d/99-web-optim.conf << EOL
# --- 1. 网络基础加速 ---
# 只有在内核编译了BBR且版本足够时才应用（由下方逻辑验证）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 2. 并发队列调优 ---
net.core.somaxconn = $SOMAXCONN
net.ipv4.tcp_max_syn_backlog = $(($SOMAXCONN * 2))
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_slow_start_after_idle = 0

# --- 3. 连接回收与安全 ---
# 注意：tcp_tw_reuse 对内核 4.12+ 主要是针对从连接，NAT 环境谨慎
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 20
net.ipv4.ip_local_port_range = 1024 65535

# --- 4. 内存与文件系统 ---
vm.swappiness = $SWAPPINESS
fs.file-max = $(($FILE_LIMIT * 2))
# 优化磁盘缓存回写频率
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
EOL

# 4. 写入 Limits 限制
cat > /etc/security/limits.d/99-web-limits.conf << EOL
* soft nofile $FILE_LIMIT
* hard nofile $FILE_LIMIT
root soft nofile $FILE_LIMIT
root hard nofile $FILE_LIMIT
EOL

# 5. 严谨的 BBR 检测逻辑
HAS_BBR=false
# 检查内核版本 (>= 4.9)
if [ "$KERNEL_MAJOR" -gt 4 ] || { [ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -ge 9 ]; }; then
    # 进一步检查内核是否开启了 BBR 模块
    if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr; then
        HAS_BBR=true
    fi
fi

if [ "$HAS_BBR" = true ]; then
    echo "成功: 检测到环境支持 BBR，已写入配置。"
    sysctl -p /etc/sysctl.d/99-web-optim.conf > /dev/null
else
    echo "警告: 环境不支持 BBR，自动降级为默认拥塞控制。"
    sed -i '/bbr/d' /etc/sysctl.d/99-web-optim.conf
    sed -i '/fq/d' /etc/sysctl.d/99-web-optim.conf
    sysctl -p /etc/sysctl.d/99-web-optim.conf > /dev/null
fi

echo "--- 调优执行完毕 ---"
