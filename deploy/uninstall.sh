#!/usr/bin/env bash
# =============================================================================
# 卸载 / 回滚部署（不动板上固件）
#   sudo bash deploy/uninstall.sh              # 停服务、删 KlipperLCD、还原 printer.cfg
#   sudo bash deploy/uninstall.sh --purge      # 另外移除 Klipper 里的 screen_bridge 补丁
#
# 注意：本脚本无法把板子刷回原厂 Marlin —— Katapult 引导器在 0x08000000，
#       要回原厂需要 SWD 重写引导器（32KiB 偏移）+ 官方固件（见 README「回滚」）。
# =============================================================================
set -euo pipefail

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

USER_NAME="${SUDO_USER:-klipper}"
[[ "$USER_NAME" == "root" ]] && USER_NAME="klipper"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
KLIPPER_DIR="${KLIPPER_DIR:-$HOME_DIR/klipper}"
CFG_DIR="$HOME_DIR/printer_data/config"

info(){ echo "[INFO] $*"; }
[[ $EUID -eq 0 ]] || { echo "请用 root/sudo 运行" >&2; exit 1; }

info "停止并移除 KlipperLCD"
systemctl stop KlipperLCD 2>/dev/null || true
systemctl disable KlipperLCD 2>/dev/null || true
rm -f /etc/systemd/system/KlipperLCD.service
systemctl daemon-reload

info "移除 nmcli 免密规则"
rm -f /etc/sudoers.d/klipper-nmcli

if [[ -f "$CFG_DIR/printer.cfg" ]]; then
  LAST_BAK="$(ls -1t "$CFG_DIR"/printer.cfg.bak.* 2>/dev/null | head -1 || true)"
  if [[ -n "$LAST_BAK" ]]; then
    info "还原 printer.cfg ← $LAST_BAK"
    mv -f "$LAST_BAK" "$CFG_DIR/printer.cfg"
  else
    info "没有备份，printer.cfg 保持原样"
  fi
fi

if [[ $PURGE -eq 1 ]]; then
  info "移除 Klipper 内的 screen_bridge 补丁"
  rm -f "$KLIPPER_DIR/klippy/extras/screen_bridge.py" "$KLIPPER_DIR/src/stm32/screen_bridge.c"
  MK="$KLIPPER_DIR/src/stm32/Makefile"
  [[ -f "$MK" ]] && sed -i '/CONFIG_WANT_SCREEN_BRIDGE/d' "$MK"
  KC="$KLIPPER_DIR/src/stm32/Kconfig"
  if [[ -f "$KC" ]]; then
    python3 - "$KC" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"\nconfig WANT_SCREEN_BRIDGE.*?range 1200 4500000\n", "\n", s, flags=re.S)
open(p, "w").write(s)
PY
  fi
  info "补丁已移除（Klipper 需重新编译才生效）"
fi

systemctl restart klipper 2>/dev/null || true
info "完成。板上固件（Katapult + Klipper）未改动。"
