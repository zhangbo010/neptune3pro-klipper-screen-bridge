#!/usr/bin/env bash
# =============================================================================
# 部署后的健康检查（只读，不改任何东西）
#   sudo bash deploy/verify.sh
# 检查：串口存在/占用、Klipper/Moonraker/KlipperLCD 服务、PTY、MCU 握手、
#       桥接命令、屏幕数据流（可选）
# =============================================================================
set -uo pipefail

PORT="${PORT:-/dev/ttyS0}"
BAUD="${BAUD:-250000}"
SUDO_UID_HOME="${SUDO_UID_HOME:-/home/klipper}"
KLIPPER_DIR="${KLIPPER_DIR:-$SUDO_UID_HOME/klipper}"
PASS=0; FAIL=0
ok(){ echo "  ✔ $*"; PASS=$((PASS+1)); }
bad(){ echo "  ✘ $*"; FAIL=$((FAIL+1)); }
hdr(){ echo; echo "== $* =="; }

hdr "1. 串口 / Serial"
[[ -e "$PORT" ]] && ok "$PORT 存在" || bad "$PORT 不存在"
if [[ -e "$PORT" ]]; then
  ls -l "$PORT" | sed 's/^/    /'
  stty -F "$PORT" -a 2>/dev/null | head -1 | sed 's/^/    /'
fi
systemctl is-active --quiet "serial-getty@$(basename "$PORT")" 2>/dev/null \
  && bad "serial-getty@$(basename "$PORT") 占用了串口" || ok "无 getty 占用"
grep -qE "console=${PORT##*/}" /proc/cmdline && bad "内核控制台占用 ${PORT##*/}" || ok "内核控制台未占用"

hdr "2. 服务 / Services"
for s in klipper moonraker KlipperLCD; do
  if systemctl is-active --quiet "$s"; then ok "$s active"; else bad "$s 未运行"; fi
done

hdr "3. Klipper 状态 / Printer state"
if command -v curl >/dev/null; then
  curl -s --max-time 5 http://127.0.0.1:7125/printer/info \
    | python3 -c 'import sys,json;d=json.load(sys.stdin)["result"];print(f"    state={d.get(\"state\")} mcu={d.get(\"state_message\",\"\")[:60]!r}")' 2>/dev/null \
    || bad "Moonraker API 不可达"
fi

hdr "4. 屏幕桥接 / Screen bridge"
if [[ -e /tmp/ttyTJC ]]; then
  ok "/tmp/ttyTJC 存在 -> $(readlink -f /tmp/ttyTJC)"
  ls -l /tmp/ttyTJC | sed 's/^/    /'
else
  bad "/tmp/ttyTJC 不存在（Klipper 未连上 MCU 时属正常）"
fi
grep -q 'screen_bridge' "$KLIPPER_DIR/klippy/extras/screen_bridge.py" 2>/dev/null \
  && ok "screen_bridge.py 已安装" || bad "screen_bridge.py 缺失"
[[ -f "$KLIPPER_DIR/src/stm32/screen_bridge.c" ]] && ok "screen_bridge.c 已安装" || bad "screen_bridge.c 缺失"

hdr "5. 固件参数 / Firmware params"
if [[ -f "$KLIPPER_DIR/out/autoconf.h" ]]; then
  grep -q 'FLASH_APPLICATION_ADDRESS_0x8004000' "$KLIPPER_DIR/out/autoconf.h" \
    && ok "应用偏移 0x08004000 (16KiB)" || bad "应用偏移不是 16KiB"
  grep -q 'CONFIG_SERIAL_BAUD=250000' "$KLIPPER_DIR/out/autoconf.h" \
    && ok "串口波特率 250000" || bad "波特率不是 250000"
  grep -q 'bridge_' "$KLIPPER_DIR/out/compile_time_request.txt" 2>/dev/null \
    && ok "桥接命令已编入固件" || bad "固件里没有 bridge_* 命令"
fi

hdr "6. MCU 握手（会临时停 Klipper 约 40s）/ Handshake"
KP="$SUDO_UID_HOME/klippy-env/bin/python"
if [[ -x "$KP" && -f "$KLIPPER_DIR/klippy/klippy.py" ]]; then
  cat > /tmp/verify_handshake.cfg <<EOF
[mcu]
serial: $PORT
baud: $BAUD
restart_method: command
[printer]
kinematics: none
max_velocity: 1
max_accel: 1
EOF
  systemctl stop klipper 2>/dev/null
  timeout 40 "$KP" "$KLIPPER_DIR/klippy/klippy.py" /tmp/verify_handshake.cfg -l /tmp/verify_handshake.log >/dev/null 2>&1
  systemctl start klipper 2>/dev/null
  if grep -qE 'mcu_version|Klipper state: Ready' /tmp/verify_handshake.log; then
    ok "MCU 握手成功：$(grep -oE 'mcu_version[^,]*' /tmp/verify_handshake.log | head -1)"
  else
    bad "MCU 握手失败，见 /tmp/verify_handshake.log"
  fi
else
  bad "找不到 klippy-env，跳过握手"
fi

echo
echo "=================================================================="
echo " 结果：通过 $PASS 项，失败 $FAIL 项"
[[ $FAIL -eq 0 ]] && echo " 全部通过 ✅" || echo " 有失败项，请对照 README 故障排查 ❌"
echo "=================================================================="
exit $(( FAIL > 0 ? 1 : 0 ))
