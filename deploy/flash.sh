#!/usr/bin/env bash
# =============================================================================
# 仅刷写 Klipper 固件（Katapult 在线升级，免拆机）
#   sudo bash deploy/flash.sh                 # 用仓库预编译 bin
#   sudo bash deploy/flash.sh --built         # 用 ~/klipper/out/klipper.bin
#   sudo bash deploy/flash.sh --bin /path/to/klipper.bin --port /dev/ttyS0
# 前提：板上已烧好 Katapult（16KiB 偏移，USART2 PA3/PA2 @250000）
# =============================================================================
set -euo pipefail

PORT="/dev/ttyS0"
BAUD="250000"
BIN=""
USE_BUILT=0
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
info(){ echo "${C_B}[INFO]${C_0} $*"; }
ok(){ echo "${C_G}[ OK ]${C_0} $*"; }
warn(){ echo "${C_Y}[WARN]${C_0} $*"; }
die(){ echo "${C_R}[FAIL]${C_0} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --baud) BAUD="$2"; shift 2 ;;
    --bin)  BIN="$2"; shift 2 ;;
    --built) USE_BUILT=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "请用 root/sudo 运行"
command -v python3 >/dev/null || die "缺少 python3"
[[ -e "$PORT" ]] || die "串口不存在：$PORT"

if [[ -z "$BIN" ]]; then
  if [[ $USE_BUILT -eq 1 ]]; then
    BIN="/home/${SUDO_USER:-klipper}/klipper/out/klipper.bin"
  else
    BIN="$REPO_DIR/artifacts/klipper_F401_USART2_J17_bridge.bin"
  fi
fi
[[ -f "$BIN" ]] || die "找不到固件：$BIN"

KATAPULT_DIR="${KATAPULT_DIR:-/home/${SUDO_USER:-klipper}/katapult}"
if [[ ! -f "$KATAPULT_DIR/scripts/flashtool.py" ]]; then
  info "克隆 Katapult"
  git clone --depth=1 https://github.com/Arksine/katapult.git "$KATAPULT_DIR"
fi

info "固件 : $BIN ($(stat -c%s "$BIN") B, sha256=$(sha256sum "$BIN" | cut -d' ' -f1))"
info "串口 : $PORT @ $BAUD"
warn "刷写期间不要断电；失败可用 ST-Link SWD 救回（Katapult 在 0x08000000，应用在 0x08004000）"

systemctl stop klipper 2>/dev/null || true
sleep 1

info "请求进入 Katapult 引导器（-r）"
if ! python3 "$KATAPULT_DIR/scripts/flashtool.py" -d "$PORT" -b "$BAUD" -r; then
  warn "进入失败：J1 5(RESET)-6(GND) 快速短接两次，或断电重上电后重试；也可先手动执行："
  warn "  python3 $KATAPULT_DIR/scripts/flashtool.py -d $PORT -b $BAUD -r"
fi
sleep 0.5

info "写入固件"
python3 "$KATAPULT_DIR/scripts/flashtool.py" -d "$PORT" -b "$BAUD" -f "$BIN"

systemctl start klipper 2>/dev/null || true
ok "刷写完成，Klipper 已启动"
warn "若 Klipper 仍报 Unable to connect，等 3 秒后 systemctl restart klipper，或查看 journalctl -u klipper -n 50"
