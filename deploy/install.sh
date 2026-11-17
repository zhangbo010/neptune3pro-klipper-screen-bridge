#!/usr/bin/env bash
# =============================================================================
# 一键部署 / One-click deploy
#   Elegoo Neptune 3 Pro (ZNP Robin Nano_DW V2.2 / STM32F401RCT6)
#   + MKS Pi (Armbian/Debian, UART0 = /dev/ttyS0)
#   + 原厂 TJC 串口屏经由 MCU USART6 (PA12/PA11) 透明桥接 + KlipperLCD
#
# 用法 / Usage:
#   sudo bash deploy/install.sh --flash --yes
#   sudo bash deploy/install.sh --dry-run            # 只看会做什么
#   sudo bash deploy/install.sh --skip-lcd           # 不装屏幕服务
#
# 该脚本可重复执行（幂等）：已存在的项会跳过或就地更新。
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------- 默认参数 ---
KLIPPER_DIR=""
KATAPULT_DIR=""
LCD_DIR=""
SERIAL_PORT="/dev/ttyS0"
BAUD="250000"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DO_PATCH=1     # 给 Klipper 打 screen_bridge 补丁
DO_CONFIG=1    # 安装 printer.cfg
DO_LCD=1       # 安装 KlipperLCD + systemd
DO_BUILD=0     # 从源码重编固件
DO_FLASH=0     # 通过 Katapult 在线刷固件
ASSUME_YES=0
DRY_RUN=0

# ---------------------------------------------------------------- 参数解析 ---
usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

选项 / Options:
  --klipper-dir DIR   Klipper 目录（默认 /home/<user>/klipper）
  --katapult-dir DIR  Katapult 目录（默认 /home/<user>/katapult）
  --lcd-dir DIR       KlipperLCD 目录（默认 /home/<user>/KlipperLCD）
  --port DEV          主机串口（默认 /dev/ttyS0）
  --baud N            主机波特率（默认 250000）
  --build             部署后从源码编译 Klipper 固件
  --flash             部署后用 Katapult 在线刷写固件（需先烧过 Katapult）
  --no-patch          跳过 Klipper 补丁
  --no-config         跳过 printer.cfg
  --skip-lcd          跳过 KlipperLCD
  --yes               非交互确认
  --dry-run           只打印将要执行的命令
  -h, --help          显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --klipper-dir)  KLIPPER_DIR="$2"; shift 2 ;;
    --katapult-dir) KATAPULT_DIR="$2"; shift 2 ;;
    --lcd-dir)      LCD_DIR="$2"; shift 2 ;;
    --port)         SERIAL_PORT="$2"; shift 2 ;;
    --baud)         BAUD="$2"; shift 2 ;;
    --build)        DO_BUILD=1; shift ;;
    --flash)        DO_FLASH=1; shift ;;
    --no-patch)     DO_PATCH=0; shift ;;
    --no-config)    DO_CONFIG=0; shift ;;
    --skip-lcd)     DO_LCD=0; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- 基础函数 ---
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info() { echo "${C_B}[INFO]${C_0} $*"; }
ok()   { echo "${C_G}[ OK ]${C_0} $*"; }
warn() { echo "${C_Y}[WARN]${C_0} $*"; }
die()  { echo "${C_R}[FAIL]${C_0} $*" >&2; exit 1; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  + $*"
  else
    "$@"
  fi
}
run_sh() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  + $*"
  else
    bash -c "$*"
  fi
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ -t 0 ]] || die "非交互模式请加 --yes"
  read -r -p "$1 [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------- 环境探测 ---
[[ $EUID -eq 0 ]] || die "请用 root/sudo 运行：sudo bash deploy/install.sh"

if [[ -z "${KLIPPER_USER:-}" ]]; then
  if id klipper >/dev/null 2>&1; then KLIPPER_USER="klipper"
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then KLIPPER_USER="$SUDO_USER"
  else KLIPPER_USER="klipper"; fi
fi
KLIPPER_HOME="$(getent passwd "$KLIPPER_USER" | cut -d: -f6)"
[[ -n "$KLIPPER_HOME" ]] || die "找不到用户 $KLIPPER_USER 的家目录"

KLIPPER_DIR="${KLIPPER_DIR:-$KLIPPER_HOME/klipper}"
KATAPULT_DIR="${KATAPULT_DIR:-$KLIPPER_HOME/katapult}"
LCD_DIR="${LCD_DIR:-$KLIPPER_HOME/KlipperLCD}"
PRINTER_CFG_DIR="$KLIPPER_HOME/printer_data/config"

echo "=================================================================="
echo " Neptune 3 Pro 一键部署 / One-click deploy"
echo "=================================================================="
info "仓库目录   : $REPO_DIR"
info "运行用户   : $KLIPPER_USER ($KLIPPER_HOME)"
info "Klipper    : $KLIPPER_DIR"
info "Katapult   : $KATAPULT_DIR"
info "KlipperLCD : $LCD_DIR"
info "主机串口   : $SERIAL_PORT @ $BAUD"
info "动作       : patch=$DO_PATCH config=$DO_CONFIG lcd=$DO_LCD build=$DO_BUILD flash=$DO_FLASH"
[[ $DRY_RUN -eq 1 ]] && warn "DRY-RUN：只打印命令，不做任何修改"
echo "=================================================================="

# ---------------------------------------------------------------- 0. 预检 ---
stage_preflight() {
  info "步骤 0/8  环境预检"
  [[ -d "$REPO_DIR/src/klipper_bridge" ]] || die "仓库不完整：找不到 src/klipper_bridge"
  [[ -d "$REPO_DIR/artifacts" ]]          || die "仓库不完整：找不到 artifacts"

  [[ -d "$KLIPPER_DIR" ]] || die "找不到 Klipper 目录：$KLIPPER_DIR
请先用 KIAUH 安装 Klipper+Moonraker+Mainsail：
  cd ~ && git clone https://github.com/dw-0/kiauh.git && ./kiauh/kiauh.sh
或显式指定：--klipper-dir /path/to/klipper"

  command -v python3 >/dev/null || die "缺少 python3"
  command -v git >/dev/null || die "缺少 git"

  if [[ ! -e "$SERIAL_PORT" ]]; then
    warn "串口 $SERIAL_PORT 不存在（若用 USB 转串口请用 --port 指定）"
  else
    ok "串口存在：$SERIAL_PORT"
  fi

  if [[ -e "$SERIAL_PORT" ]]; then
    if systemctl is-active --quiet "serial-getty@$(basename "$SERIAL_PORT")" 2>/dev/null; then
      warn "serial-getty@$(basename "$SERIAL_PORT") 正在占用串口，将尝试禁用"
      run systemctl disable --now "serial-getty@$(basename "$SERIAL_PORT")" || true
    fi
  fi

  if grep -qE "console=${SERIAL_PORT##*/}" /proc/cmdline 2>/dev/null; then
    die "内核控制台占用了 ${SERIAL_PORT##*/}；请先在 armbianEnv.txt/bootargs 里把 console 移到别的串口（如 ttyS2）"
  fi

  if id -nG "$KLIPPER_USER" | tr ' ' '\n' | grep -qx dialout; then
    ok "$KLIPPER_USER 已在 dialout 组"
  else
    info "把 $KLIPPER_USER 加入 dialout 组"
    run usermod -aG dialout "$KLIPPER_USER"
  fi
}

# ------------------------------------------------------- 1. 打 Klipper 补丁 ---
stage_patch() {
  [[ $DO_PATCH -eq 1 ]] || { info "跳过 Klipper 补丁"; return; }
  info "步骤 1/8  安装 screen_bridge 到 Klipper"

  local src_c="$KLIPPER_DIR/src/stm32/screen_bridge.c"
  local dst_py="$KLIPPER_DIR/klippy/extras/screen_bridge.py"

  run install -m 0644 "$REPO_DIR/src/klipper_bridge/screen_bridge.c" "$src_c"
  run install -m 0644 "$REPO_DIR/src/klipper_bridge/screen_bridge.py" "$dst_py"
  run chown -R "$KLIPPER_USER:$KLIPPER_USER" "$src_c" "$dst_py"
  ok "已复制 screen_bridge.c / screen_bridge.py"

  # --- Makefile：加一行编译规则（幂等）
  local mk="$KLIPPER_DIR/src/stm32/Makefile"
  if grep -q 'CONFIG_WANT_SCREEN_BRIDGE' "$mk"; then
    ok "Makefile 已包含 SCREEN_BRIDGE 规则"
  else
    info "向 src/stm32/Makefile 插入编译规则"
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  + 在 src/stm32/Makefile 的 CONFIG_SERIAL 行后插入 src-\$(CONFIG_WANT_SCREEN_BRIDGE) += stm32/screen_bridge.c"
    else
      awk '
        BEGIN{ done=0 }
        { print }
        /^src-\$\(CONFIG_SERIAL\)/ && !done {
          print "src-$(CONFIG_WANT_SCREEN_BRIDGE) += stm32/screen_bridge.c"
          done=1
        }
        END{ if(!done) print "src-$(CONFIG_WANT_SCREEN_BRIDGE) += stm32/screen_bridge.c" }
      ' "$mk" > "$mk.new" && mv "$mk.new" "$mk"
      grep -q 'screen_bridge.c' "$mk" || die "Makefile 插入失败"
      ok "Makefile 已插入"
    fi
  fi

  # --- Kconfig：加模块开关（幂等）
  local kc="$KLIPPER_DIR/src/stm32/Kconfig"
  if grep -q 'config WANT_SCREEN_BRIDGE' "$kc"; then
    ok "Kconfig 已包含 WANT_SCREEN_BRIDGE"
  else
    info "向 src/stm32/Kconfig 插入模块开关"
    local block='config WANT_SCREEN_BRIDGE
    bool "Serial screen UART bridge (USART6 PA12/PA11)"
    depends on MACH_STM32F4
    depends on !STM32_SERIAL_USART6 && !STM32_SERIAL_USART6_ALT_PC7_PC6
    default n
    help
      Second UART on USART6 (PA12 RX / PA11 TX) bridged to the Klipper
      host as a byte pipe. For a Nextion/TJC serial display.

config STM32_SCREEN_BRIDGE_BAUD
    int "Screen bridge baud rate"
    depends on WANT_SCREEN_BRIDGE
    default 115200
    range 1200 4500000
'
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  + 在 src/stm32/Kconfig 最后一个 endif 前插入 WANT_SCREEN_BRIDGE / STM32_SCREEN_BRIDGE_BAUD"
    else
      local last_endif
      last_endif="$(grep -n '^endif' "$kc" | tail -1 | cut -d: -f1 || true)"
      if [[ -n "$last_endif" ]]; then
        { head -n $((last_endif-1)) "$kc"; printf '%s\n' "$block"; tail -n +"$last_endif" "$kc"; } > "$kc.new" && mv "$kc.new" "$kc"
      else
        printf '\n%s\n' "$block" >> "$kc"
      fi
      grep -q 'config WANT_SCREEN_BRIDGE' "$kc" || die "Kconfig 插入失败"
      ok "Kconfig 已插入"
    fi
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    python3 -m py_compile "$dst_py" || die "screen_bridge.py 语法错误"
    ok "screen_bridge.py 语法检查通过"
  fi
}

# -------------------------------------------------------- 2. 安装 printer.cfg ---
stage_config() {
  [[ $DO_CONFIG -eq 1 ]] || { info "跳过 printer.cfg"; return; }
  info "步骤 2/8  安装 printer.cfg"
  mkdir -p "$PRINTER_CFG_DIR"
  local dst="$PRINTER_CFG_DIR/printer.cfg"
  if [[ -f "$dst" ]]; then
    local bak="$dst.bak.$(date +%Y%m%d_%H%M%S)"
    run cp -a "$dst" "$bak"
    ok "已备份原配置：$bak"
  fi
  run install -m 0644 "$REPO_DIR/src/config/printer.cfg" "$dst"

  if [[ $DRY_RUN -eq 0 ]]; then
    # 串口/波特率按参数落地
    sed -i "s|^serial:.*|serial: $SERIAL_PORT|" "$dst"
    sed -i "s|^baud:.*|baud: $BAUD|" "$dst"
    # 依赖文件不存在时注释掉 include，避免 Klipper 起不来
    for inc in mainsail.cfg plr.cfg; do
      if [[ ! -f "$PRINTER_CFG_DIR/$inc" ]]; then
        sed -i "s|^\[include $inc\]|# [include $inc]  # missing: $inc|" "$dst"
        warn "缺少 $inc，已在 printer.cfg 中注释"
      fi
    done
    run chown -R "$KLIPPER_USER:$KLIPPER_USER" "$dst"
  fi
  ok "printer.cfg 已安装（串口 $SERIAL_PORT @ $BAUD）"
}

# ---------------------------------------------------------- 3. 安装 KlipperLCD ---
stage_lcd() {
  [[ $DO_LCD -eq 1 ]] || { info "跳过 KlipperLCD"; return; }
  info "步骤 3/8  安装 KlipperLCD（屏幕服务 + WiFi 面板）"

  if [[ ! -d "$LCD_DIR" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  + git clone https://github.com/joakimtoe/KlipperLCD.git $LCD_DIR"
    else
      if ! run git clone --depth=1 https://github.com/joakimtoe/KlipperLCD.git "$LCD_DIR"; then
        warn "无法克隆 KlipperLCD（离线？），将仅使用本仓库内置文件"
        mkdir -p "$LCD_DIR"
      fi
    fi
  fi

  run install -m 0644 "$REPO_DIR/src/KlipperLCD/main.py"       "$LCD_DIR/main.py"
  run install -m 0644 "$REPO_DIR/src/KlipperLCD/lcd.py"        "$LCD_DIR/lcd.py"
  run install -m 0644 "$REPO_DIR/src/KlipperLCD/printer.py"    "$LCD_DIR/printer.py"
  run install -m 0644 "$REPO_DIR/src/KlipperLCD/lib_col_pic.py" "$LCD_DIR/lib_col_pic.py"
  run chown -R "$KLIPPER_USER:$KLIPPER_USER" "$LCD_DIR"
  ok "KlipperLCD 源码已就位"

  # pyserial
  if python3 -c 'import serial' >/dev/null 2>&1; then
    ok "pyserial 已安装"
  else
    info "安装 pyserial"
    if command -v apt-get >/dev/null; then
      run_sh "apt-get install -y python3-serial" || run_sh "pip3 install pyserial --break-system-packages"
    else
      run_sh "pip3 install pyserial --break-system-packages"
    fi
  fi

  # systemd
  local svc=/etc/systemd/system/KlipperLCD.service
  info "安装 systemd 服务：$svc"
  if [[ $DRY_RUN -eq 0 ]]; then
    cat > "$svc" <<EOF
[Unit]
Description=KlipperLCD Service (Neptune 3 Pro TJC Screen via /tmp/ttyTJC)
After=klipper.service moonraker.service

[Service]
Type=simple
User=$KLIPPER_USER
WorkingDirectory=$LCD_DIR
Restart=always
RestartSec=2
ExecStart=/usr/bin/env python3 -u $LCD_DIR/main.py

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable KlipperLCD.service
  else
    echo "  + 写入 $svc 并 systemctl enable KlipperLCD"
  fi

  # WiFi 面板需要免密 nmcli
  local sdf=/etc/sudoers.d/klipper-nmcli
  if [[ -f "$sdf" ]] && grep -q nmcli "$sdf"; then
    ok "nmcli 免密规则已存在"
  else
    info "授权 $KLIPPER_USER 免密执行 nmcli（WiFi 面板用）"
    if [[ $DRY_RUN -eq 0 ]]; then
      echo "$KLIPPER_USER ALL=(ALL) NOPASSWD: /usr/bin/nmcli" > "$sdf"
      chmod 440 "$sdf"
      visudo -cf "$sdf" >/dev/null || { rm -f "$sdf"; die "sudoers 校验失败"; }
    else
      echo "  + 写入 $sdf"
    fi
  fi
  ok "KlipperLCD 安装完成"
}

# --------------------------------------------------------------- 4. 编译 ---
stage_build() {
  [[ $DO_BUILD -eq 1 ]] || { info "跳过编译（将使用仓库预编译 bin）"; return; }
  info "步骤 4/8  从源码编译 Klipper 固件"
  if ! command -v arm-none-eabi-gcc >/dev/null; then
    warn "缺少 arm-none-eabi-gcc"
    info "安装：sudo apt-get install -y gcc-arm-none-eabi binutils-arm-none-eabi"
    if confirm "是否现在安装编译工具链？"; then
      run_sh "apt-get update && apt-get install -y gcc-arm-none-eabi binutils-arm-none-eabi"
    else
      die "缺少工具链，无法编译"
    fi
  fi
  run cp "$REPO_DIR/src/klipper_bridge/.config" "$KLIPPER_DIR/.config"
  run_sh "cd '$KLIPPER_DIR' && make olddefconfig && make -j\$(nproc)"
  if [[ $DRY_RUN -eq 0 ]]; then
    grep -q '^CONFIG_WANT_SCREEN_BRIDGE=y' "$KLIPPER_DIR/.config" || die ".config 缺 WANT_SCREEN_BRIDGE"
    grep -q 'FLASH_APPLICATION_ADDRESS_0x8004000' "$KLIPPER_DIR/out/autoconf.h" || die "固件不是 16KiB 偏移(0x8004000)，拒绝继续"
    grep -q 'bridge_' "$KLIPPER_DIR/out/compile_time_request.txt" || die "桥接命令未编进固件"
    ok "编译完成：$KLIPPER_DIR/out/klipper.bin ($(stat -c%s "$KLIPPER_DIR/out/klipper.bin") B)"
  fi
}

# --------------------------------------------------------------- 5. 烧录 ---
stage_flash() {
  [[ $DO_FLASH -eq 1 ]] || { info "跳过烧录（需要时单独执行 deploy/flash.sh）"; return; }
  info "步骤 5/8  通过 Katapult 在线刷写 Klipper 固件（16KiB @0x08004000）"

  local bin
  if [[ $DO_BUILD -eq 1 && -f "$KLIPPER_DIR/out/klipper.bin" ]]; then
    bin="$KLIPPER_DIR/out/klipper.bin"
  else
    bin="$REPO_DIR/artifacts/klipper_F401_USART2_J17_bridge.bin"
  fi
  [[ -f "$bin" ]] || {
    if [[ $DRY_RUN -eq 1 ]]; then info "DRY-RUN: 固件尚不存在（--build 后会生成）：$bin"; return; fi
    die "找不到固件：$bin"
  }

  if [[ ! -f "$KATAPULT_DIR/scripts/flashtool.py" ]]; then
    info "克隆 Katapult（只为用 flashtool.py）"
    run git clone --depth=1 https://github.com/Arksine/katapult.git "$KATAPULT_DIR"
  fi

  warn "即将通过 $SERIAL_PORT 刷写 $bin（$(stat -c%s "$bin") B）"
  warn "刷写期间不要断电；失败可用 ST-Link SWD 救回"
  confirm "确认继续刷写？" || die "用户取消"

  run systemctl stop klipper || true
  sleep 1
  if ! run_sh "python3 '$KATAPULT_DIR/scripts/flashtool.py' -d '$SERIAL_PORT' -b '$BAUD' -r"; then
    warn "进入 Katapult 失败：可 J1 5-6 双击复位，或断电重上电后重试"
  fi
  sleep 0.5
  run_sh "python3 '$KATAPULT_DIR/scripts/flashtool.py' -d '$SERIAL_PORT' -b '$BAUD' -f '$bin'"
  run systemctl start klipper || true
  ok "固件刷写完成"
}

# --------------------------------------------------------------- 6. 服务 ---
stage_services() {
  info "步骤 6/8  重启服务"
  run systemctl restart klipper || true
  run systemctl restart moonraker || true
  [[ $DO_LCD -eq 1 ]] && run systemctl restart KlipperLCD || true
  ok "服务已重启"
}

# --------------------------------------------------------------- 7. 验证 ---
stage_verify() {
  info "步骤 7/8  验证"
  if [[ $DRY_RUN -eq 1 ]]; then echo "  + 验证服务/PTY/握手"; return; fi
  sleep 3
  for s in klipper moonraker KlipperLCD; do
    [[ $s == KlipperLCD && $DO_LCD -eq 0 ]] && continue
    if systemctl is-active --quiet "$s"; then ok "$s: active"; else warn "$s: 未运行（journalctl -u $s -n 30）"; fi
  done
  [[ -e /tmp/ttyTJC ]] && ok "/tmp/ttyTJC 已创建" || warn "/tmp/ttyTJC 不存在（Klipper 未连上 MCU 时正常）"

  # 最小握手测试（不接屏也能做）
  local kp="$KLIPPER_HOME/klippy-env/bin/python"
  [[ -x "$kp" ]] || { warn "未找到 klippy-env，跳过握手测试"; return; }
  local tcfg=/tmp/oneclick_handshake.cfg
  cat > "$tcfg" <<EOF
[mcu]
serial: $SERIAL_PORT
baud: $BAUD
restart_method: command
[printer]
kinematics: none
max_velocity: 1
max_accel: 1
EOF
  systemctl stop klipper || true
  timeout 40 "$kp" "$KLIPPER_DIR/klippy/klippy.py" "$tcfg" -l /tmp/oneclick_handshake.log || true
  systemctl start klipper || true
  if grep -qE 'mcu_version|Klipper state: Ready' /tmp/oneclick_handshake.log; then
    ok "MCU 握手成功（$(grep -oE 'mcu_version[^,]*' /tmp/oneclick_handshake.log | head -1)）"
  else
    warn "MCU 握手失败，见 /tmp/oneclick_handshake.log"
  fi
}

# --------------------------------------------------------------- 8. 总结 ---
stage_summary() {
  info "步骤 8/8  完成"
  cat <<EOF

==================================================================
 部署完成 / Deploy finished
------------------------------------------------------------------
 Klipper     : $KLIPPER_DIR
 配置        : $PRINTER_CFG_DIR/printer.cfg
 KlipperLCD  : $LCD_DIR  (systemd: KlipperLCD)
 MCU         : $SERIAL_PORT @ $BAUD  (USART2 PA3/PA2 ← 主板 J17)
 屏幕 PTY    : /tmp/ttyTJC          (USART6 PA12/PA11 @115200 ← 主板 J33)

 下一步 / Next:
   1) 打开 Mainsail/Fluidd 看 Klipper 是否 Ready
   2) QUERY_ENDSTOPS / STEPPER_BUZZ 逐个验证电机与限位
   3) 首次 G28 手放急停；确认无误后跑 PID_CALIBRATE
   4) 屏幕：Macro 页选 WiFi → Console 页输密码
 升级固件    : sudo bash $REPO_DIR/deploy/flash.sh
==================================================================
EOF
}

# ---------------------------------------------------------------- 主流程 ---
stage_preflight
stage_patch
stage_config
stage_lcd
stage_build
stage_flash
stage_services
stage_verify
stage_summary
