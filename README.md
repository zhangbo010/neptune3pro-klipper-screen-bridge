# Elegoo Neptune 3 Pro · 无损改 Klipper · 原厂串口屏桥接 · 一键部署

[English](README.en.md) | **中文**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Klipper](https://img.shields.io/badge/Klipper-v0.13.x-green)
![MCU](https://img.shields.io/badge/MCU-STM32F401RCT6-orange)
![Host](https://img.shields.io/badge/Host-MKS%20Pi%20%2F%20Armbian-lightgrey)

> **不改屏线、不焊主板、不拆屏**：Elegoo 海王星 3 Pro 原厂主板（ZNP Robin Nano_DW V2.2 / STM32F401RCT6）
> 刷 Klipper 后，原厂 4P4C 电话线串口屏继续可用 —— 靠 **MCU 固件内部 UART 桥接**，
> 屏幕数据经主板 J33 → `USART6 PA12/PA11` → Klipper 字节管道 → 上位机 PTY `/tmp/ttyTJC` → KlipperLCD。
> 主机与主板之间也不再占用 USB 口，而是走主板 **J17（原 WiFi 座）= `USART2 PA3/PA2`** 三根线直连 MKS Pi `UART0`。

- 状态：**已实测打通**（2026-11-11，Klipper `state: ready`，0 重传 / 0 丢包，屏幕热插拔自动重连）
- 固件布局：**Katapult `@0x08000000`（16 KiB 引导区）+ Klipper `@0x08004000`（16 KiB 偏移）**
- 附带：屏幕 **WiFi 扫描/连接面板**（含热插拔重初始化）、**一键部署脚本**、完整踩坑复盘

---

## 一、架构

```text
                 J17 (USART2 PA3/PA2, 250000 8N1, 3.3V TTL)
   ┌──────────────────────┐   GND / TXD2 / RXD2   ┌──────────────────────────┐
   │  Elegoo Neptune 3 Pro│◄──── 3 线直连 ───────►│  MKS Pi V1.1 (Armbian)   │
   │  ZNP Robin Nano_DW   │                       │  /dev/ttyS0 (UART0)      │
   │  V2.2 / STM32F401RCT6│                       │  Klipper + Moonraker     │
   │                      │                       │  screen_bridge.py        │
   │   ┌───────────────┐  │  J33 (USART6 PA12/PA11, 115200 8N1)  │  /tmp/ttyTJC (PTY)   │
   │   │ 原厂 TJC 屏    │  │◄─── 原厂电话线直插 ───►│  KlipperLCD              │
   │   │ TJC4827X243_011│  │                       └──────────────────────────┘
   │   └───────────────┘  │
   └──────────────────────┘
```

| 链路 | 接口 | 引脚 | 波特率 |
|---|---|---|---|
| 上位机 ↔ 主板 | 主板 `J17` ↔ Pi `UART0` `/dev/ttyS0` | `PA2(TXD2)` / `PA3(RXD2)` / `GND` | **250000** |
| 主板 ↔ 原厂屏 | 主板 `J33`（4P4C 电话线） | `PA11(TXD6)` / `PA12(RXD6)` | **115200** |
| 上位机 ↔ 屏幕服务 | Klipper `[screen_bridge]` → PTY | `/tmp/ttyTJC` | 115200 |

---

## 二、三个地址、两个波特率（动手前先记住）

| 项 | 值 | 说明 |
|---|---|---|
| Katapult 起始地址 | `0x08000000` | 占 16 KiB 引导区，bin 约 2.3 KB |
| Klipper 起始地址 | **`0x08004000`** | **16 KiB 偏移，不是 32 KiB** |
| 主机链路 | `USART2 PA3(RX)/PA2(TX)`，J17，**250000** | 到 Pi `/dev/ttyS0` |
| 屏幕链路 | `USART6 PA12(RX)/PA11(TX)`，J33，**115200** | 原电话线直插，MCU 桥接 |

> ⚠️ **三个致命坑**
> 1. **Klipper 不能烧到 `0x08000000`** —— 会覆盖引导器，之后只能 SWD 救砖。
> 2. **屏幕口不是 `USART6 PC7/PC6`** —— 那是 `Z_STEP` / `E0_EN`，会抢运动引脚；本机是 `PA12/PA11`。
> 3. **不要混用旧产物** —— 旧版是 32 KiB 偏移 / 500000 波特率，最终版是 **16 KiB / 250000**（`out/klipper.bin` 35,864 B，Reset `0x08004271`）。

---

## 三、仓库结构

```text
neptune3pro-klipper-screen-bridge/
├── README.md / README.en.md           # 中 / 英 说明（本文）
├── LICENSE                            # GPL-3.0
├── deploy/
│   ├── install.sh                     # ★ 一键部署（打补丁 + 配置 + 屏幕服务 + 可选刷机）
│   ├── flash.sh                       # 仅在线升级固件（Katapult）
│   ├── verify.sh                      # 部署后健康检查（只读）
│   └── uninstall.sh                   # 卸载/回滚部署（不动板上固件）
├── src/
│   ├── klipper_bridge/
│   │   ├── screen_bridge.c            # MCU 侧：USART6(PA12/PA11) ↔ Klipper 字节管道
│   │   ├── screen_bridge.py           # 上位机侧：PTY /tmp/ttyTJC（热插拔保活）
│   │   └── .config                    # Klipper 编译配置（F401xc / 16KiB / USART2 / WANT_SCREEN_BRIDGE）
│   ├── KlipperLCD/                    # main.py / lcd.py / printer.py / lib_col_pic.py / service
│   └── config/printer.cfg             # 海王星 3 Pro 最终版配置
├── artifacts/
│   ├── katapult_F401_USART2_J17.bin           # 引导器 @0x08000000（2,286 B）
│   ├── klipper_F401_USART2_J17_bridge.bin     # 应用固件 @0x08004000（35,864 B）
│   └── 20240129.tft                           # TJC4827X243_011 屏幕固件（6.6 MB）
└── docs/
    ├── RUNBOOK.zh.md                  # 完整流程（编译→烧录→配置→排查）
    ├── 改造方案与踩坑总结.md           # 方案与 6 大踩坑复盘
    ├── 烧录说明.txt                    # 双段固件地址速查
    └── ZNP_Robin_Nano_DW_V2.2_SCH.pdf # 主板官方原理图
```

---

## 四、一键部署（推荐）

前提：MKS Pi 上已用 KIAUH 装好 **Klipper + Moonraker + Mainsail**，且板上已烧过 **Katapult**（见 §6.2）。

```bash
# 1) 拉脚本并执行（会打补丁、装配置、装屏幕服务、重启服务，并按需在线刷固件）
curl -fsSL https://raw.githubusercontent.com/zhangbo010/neptune3pro-klipper-screen-bridge/main/deploy/install.sh \
  -o /tmp/install.sh
sudo bash /tmp/install.sh --flash --yes

# 2) 健康检查
curl -fsSL https://raw.githubusercontent.com/zhangbo010/neptune3pro-klipper-screen-bridge/main/deploy/verify.sh -o /tmp/verify.sh
sudo bash /tmp/verify.sh
```

或先 clone 再本地执行：

```bash
git clone https://github.com/zhangbo010/neptune3pro-klipper-screen-bridge.git
cd neptune3pro-klipper-screen-bridge
sudo bash deploy/install.sh --dry-run          # 先看会做什么
sudo bash deploy/install.sh --flash --yes      # 正式执行
sudo bash deploy/verify.sh                     # 验证
```

**脚本做了什么（8 步，幂等可重跑）**

| 步骤 | 动作 |
|---|---|
| 0 | 预检：Klipper 目录、python3、串口存在、getty/内核控制台占用、dialout 组 |
| 1 | 复制 `screen_bridge.c/.py` 到 Klipper 树，向 `src/stm32/Makefile`、`src/stm32/Kconfig` 打补丁（已打过则跳过） |
| 2 | 备份并安装 `printer.cfg`，按 `--port/--baud` 写入串口；缺失的 `[include]` 自动注释 |
| 3 | 安装 KlipperLCD（克隆 + 覆盖增强版），装 `pyserial`，写 systemd 服务，授权 `nmcli` 免密 |
| 4 | `--build` 时：套用 `.config`、编译、校验偏移/波特率/`bridge_*` 命令 |
| 5 | `--flash` 时：停 Klipper → Katapult `-r` 进引导器 → `-f` 写固件 → 重启 |
| 6 | 重启 Klipper / Moonraker / KlipperLCD |
| 7 | 验证：服务状态、`/tmp/ttyTJC` 是否出现、最小配置 MCU 握手（`mcu_version`） |
| 8 | 打印摘要与后续步骤 |

**常用参数**

| 参数 | 作用 |
|---|---|
| `--flash` | 部署后在线刷固件（默认不刷） |
| `--build` | 从源码编译（默认用 `artifacts/` 预编译 bin） |
| `--yes` / `-y` | 非交互确认 |
| `--dry-run` | 只打印命令，不改系统 |
| `--port /dev/ttyS0` | 主机串口 |
| `--baud 250000` | 主机波特率 |
| `--klipper-dir` / `--katapult-dir` / `--lcd-dir` | 自定义安装目录 |
| `--no-patch` / `--no-config` / `--skip-lcd` | 跳过对应步骤 |

---

## 五、详细部署步骤

### 5.1 前置条件

| 项 | 要求 |
|---|---|
| 打印机 | Elegoo Neptune 3 Pro（**不是** Neptune 3 / Neptune 4，主板不同） |
| 主板 | `ZNP Robin Nano_DW V2.2`，`STM32F401RCT6`，8 MHz 晶振 |
| 屏幕 | 原厂陶晶驰 `TJC4827X243_011`，4P4C 电话线 |
| 上位机 | MKS Pi V1.1（RK3328 / 1 GB）或任意带 3.3V UART 的 Debian ARM 主机 |
| 系统 | Armbian / Debian 12 bookworm，Klipper + Moonraker + Mainsail |
| 工具 | ST-Link（首次烧录/救砖）、杜邦线 3 根、万用表 |

```bash
# 上位机环境自检
ls -l /dev/ttyS0                                  # UART0 必须存在
cat /proc/cmdline | tr ' ' '\n' | grep console    # 控制台不能是 ttyS0
systemctl status serial-getty@ttyS0               # 必须 inactive
stty -F /dev/ttyS0 -a | head -1                   # 能查看即正常
sudo usermod -aG dialout klipper
```

Klipper 三件套（已装可跳过）：

```bash
cd ~ && git clone https://github.com/dw-0/kiauh.git && ./kiauh/kiauh.sh
# 安装：Klipper、Moonraker、Mainsail
```

### 5.2 硬件接线

**① 主板 J17（原 WiFi 模块座）↔ MKS Pi UART0** —— 3 根线，TX/RX 交叉

| J17 | 信号 | 接到 MKS Pi |
|---|---|---|
| 1 | `+5V`（模块供电输出） | **悬空，严禁接**（否则向 Pi 灌 5V） |
| 2 | `GND` | `GND`（物理 6 脚） |
| 3 | `TXD2`（`PA2`，MCU 发） | `UART0_RX`（GPIO15 / 物理 10 脚） |
| 4 | `RXD2`（`PA3`，MCU 收） | `UART0_TX`（GPIO14 / 物理 8 脚） |

> - 3.3V TTL 直连，**断电插拔**。
> - 板上 WiFi 模块（`ROBIN-WIFI`，M1）**必须拔掉**，否则并联在 USART2 上抢串口；不拔就把模块 `EN` 拉低。

**② 主板 J33（4P4C 电话线座）↔ 原厂屏** —— 零改动

- 原厂电话线**直插 J33**，不剪线、不加转接板。
- `J33.3 = TXD6 → PA11`、`J33.4 = RXD6 → PA12`；`115200 8N1`。
- 屏 5V 由 J33 第 1 脚供给（线序：黑=5V、红=GND、绿=RX、黄=TX，**按针位核，别只信颜色**）。

**③ 上电顺序**：打印机 24V → Pi 启动（约 40 s）→ Klipper → Moonraker → KlipperLCD。

### 5.3 首次烧录：Katapult 引导器（只需一次）

两种方式，任选其一。**先备份官方固件**（Elegoo 官网 SD 更新包）—— 原厂引导器会被覆盖。

**A. ST-Link SWD（推荐）**

| 信号 | 主板 J1 |
|---|---|
| 3.3V | 3.3V（只供电参考，不要接主板电源轨） |
| GND | GND |
| SWDIO | SWDIO |
| SWCLK | SWCLK |
| NRST | **本板 J1 未接**，用 `Connect under reset` |

用 STM32CubeProgrammer 选 **Connect under reset**，写 `artifacts/katapult_F401_USART2_J17.bin` 到 **`0x08000000`**，再写 `artifacts/klipper_F401_USART2_J17_bridge.bin` 到 **`0x08004000`**，断电重上电。

**B. BOOT0 + 芯片 ROM 引导器（不用 ST-Link）**

1. **J10 跳线 1-2 短接**（1 针 = BOOT0/60 脚，2 针 = +3V3），万用表量 J10-1 对 GND = **3.3V**；
2. 保持跳线，**断电再上电**（BOOT0 只在复位时采样）；
3. 主板 USB（CH340）接 Pi，认到 `/dev/ttyUSB0`；
4. 分两次写，**不要 `-e` 整片擦**：

```bash
stm32flash -b 115200 -m 8e1 -w artifacts/katapult_F401_USART2_J17.bin          -S 0x08000000 -v /dev/ttyUSB0
stm32flash -b 115200 -m 8e1 -w artifacts/klipper_F401_USART2_J17_bridge.bin    -S 0x08004000 -v /dev/ttyUSB0
```

5. 拔 J10 → 断电重上电。

> CH340 的 DTR# 经 C33 接 RESET，打开串口会给一次复位脉冲；BOOT0 已拉高时这反而是重新进 ROM 的正常现象。

### 5.4 日常在线升级（Katapult 在位，免拆机）

```bash
sudo bash deploy/flash.sh            # 用仓库预编译 bin
sudo bash deploy/flash.sh --built    # 用 ~/klipper/out/klipper.bin
```

等价于：

```bash
sudo systemctl stop klipper
python3 ~/katapult/scripts/flashtool.py -d /dev/ttyS0 -b 250000 -r
sleep 0.5
python3 ~/katapult/scripts/flashtool.py -d /dev/ttyS0 -b 250000 -f ~/klipper/out/klipper.bin
sudo systemctl start klipper && sudo systemctl restart KlipperLCD
```

- `-r` 进不去时：**J1 5(RESET)-6(GND) 快速短接两次**，或断电重上电后再执行。
- 刷前核对 flashtool 报的 SHA 与本地 `sha256sum` 一致。

### 5.5 printer.cfg

`src/config/printer.cfg` 已含最终版（引脚、风扇、`[screen_bridge]`）。核心段落：

```ini
[mcu]
serial: /dev/ttyS0
baud: 250000
restart_method: command

[screen_bridge]
pty: /tmp/ttyTJC
baud: 115200
```

> 本机专属值（换机要重标）：`extruder rotation_distance: 7.53`、`nozzle_diameter: 0.600`、
> `Z endstop: PB4`、`safe_z_home: 146.0, 95.5`。探针与 `bed_mesh` 默认注释掉；
> 装了 CR-Touch 的机器请取消注释并把 Z 改成 `probe:z_virtual_endstop`。

### 5.6 屏幕服务 KlipperLCD + WiFi 面板

一键脚本已包含；手动步骤如下：

```bash
cd ~ && git clone https://github.com/joakimtoe/KlipperLCD.git
cd KlipperLCD
cp <repo>/src/KlipperLCD/{main.py,lcd.py,printer.py,lib_col_pic.py} .
pip3 install pyserial --break-system-packages
python3 -m py_compile main.py lcd.py printer.py
sudo cp <repo>/src/KlipperLCD/KlipperLCD.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now KlipperLCD
# WiFi 面板需要免密 nmcli
echo 'klipper ALL=(ALL) NOPASSWD: /usr/bin/nmcli' | sudo tee /etc/sudoers.d/klipper-nmcli
sudo chmod 440 /etc/sudoers.d/klipper-nmcli
```

屏幕操作：

- **Macro 页**：下拉框列出 `[RESCAN_WIFI]` + 信号最强的 WiFi → 选一个 → Send → 自动跳回 Console；
- **Console 页**：点输入框弹全键盘 → 输入密码 → Send → `nmcli` 连接；密码错自动回退原网络；
- 中文 SSID 会被过滤（屏字库无中文），英文/数字 SSID 正常。

### 5.7 （可选）从源码编译固件

只有当你要改引脚/波特率/桥接逻辑时才需要。

**Katapult**（16 KiB 引导器）：

```bash
cd ~ && git clone https://github.com/Arksine/katapult.git && cd katapult
make menuconfig
#   STM32 / STM32F401 / 16KiB bootloader (0x8004000) / 8 MHz crystal
#   Serial (on USART2 PA3/PA2) / 250000 / Entry on double reset = y
make
# 产物 out/katapult.bin（最终版 2,286 B）
grep -E 'FLASH_APPLICATION_ADDRESS|SERIAL_BAUD|STM32_SERIAL_USART2 |ENABLE_DOUBLE_RESET' out/autoconf.h
```

**Klipper**（16 KiB + 屏桥接）：

```bash
cd ~/klipper
cp <repo>/src/klipper_bridge/screen_bridge.c    src/stm32/
cp <repo>/src/klipper_bridge/screen_bridge.py   klippy/extras/
# Makefile：在 src-$(CONFIG_SERIAL) 行后加
#   src-$(CONFIG_WANT_SCREEN_BRIDGE) += stm32/screen_bridge.c
# Kconfig：在 src/stm32/Kconfig 末尾（最后一个 endif 前）加 WANT_SCREEN_BRIDGE / STM32_SCREEN_BRIDGE_BAUD
cp <repo>/src/klipper_bridge/.config .config
make olddefconfig && make
# 校验
grep -E 'FLASH_APPLICATION_ADDRESS|SERIAL_BAUD=|SCREEN_BRIDGE' out/autoconf.h
grep -E 'bridge_(tx|rx|config|reset|get_stats)' out/compile_time_request.txt
xxd -l 8 out/klipper.bin     # Reset 必须是 0x08004xxx
sha256sum out/klipper.bin     # 期望 54c573d1…df957e86，35,864 B
```

`menuconfig` 关键项：`STM32F401` / **16KiB bootloader** / 8 MHz crystal / **Serial (USART2 PA3/PA2)** / 250000 / 打开 low-level options / **Serial screen UART bridge (USART6 PA12/PA11) = y** / 桥接波特率 115200。

### 5.8 上机验证清单

1. `cat /proc/tty/driver/serial`：`ttyS0` 的 tx/rx 在涨，无持续 `brk/oe`；
2. Klipper `state: ready`，`mcu_version` 与 `~/klipper` commit 对应；
3. `ls -l /tmp/ttyTJC` 存在（指向 `/dev/pts/N`）；
4. 屏亮、进主界面，温度/IP 与 Mainsail 一致；
5. **热插拔**：拔电话线 2 秒再插回，1–2 秒内自动回主界面；
6. WiFi 面板：扫描、连接、密码错误回退各测一次；
7. `STEPPER_BUZZ STEPPER=stepper_x`（x/y/z/挤出机逐个），方向不对改 `dir_pin` 的 `!`；
8. `QUERY_ENDSTOPS` 手动触发 X/Y/Z；`G28` 首次手放急停；
9. `PID_CALIBRATE HEATER=extruder TARGET=200`、`HEATER=heater_bed TARGET=60` → `SAVE_CONFIG`；
10. 空跑 20×20 方块 → 第一层 → Benchy。

---

## 六、故障排查

| 现象 | 根因 | 处理 |
|---|---|---|
| 屏没反应，Klipper 报 `Pin PC7 is reserved` | 桥接误用 `PC6/PC7`（Z_STEP/E0_EN） | 改用 `PA12/PA11`（USART6 AF8）重编 |
| 刷完 `Timeout on connect` | bin 是旧版 32 KiB / 500000 | 用 16 KiB / 250000 版，`xxd` 看 Reset=`0x08004xxx` |
| Katapult 不应答 | 已跳应用 / 错过 500 ms 窗口 | `flashtool -r`；J1 5-6 双击复位；断电重上电 |
| ST-Link `TransferError 0x06` | 旧固件上电跑飞，J1 无 NRST | `Connect under reset` + 复位瞬间 halt（见 docs） |
| 屏卡在 boot 页 | 待机无数据、屏回 `0x1A` 被丢弃 | 用本仓库增强版 `lcd.py`/`main.py`（`0x1A`/`0x88` 重初始化 + 4 s 心跳） |
| 拔插屏后 KlipperLCD 断连 | PTY 在 Klipper 重启时被销毁 | 用本仓库 `screen_bridge.py`（disconnect/shutdown 保活 + inode 跟踪） |
| 主机串口丢包/重传 | 波特率不是 250000 | Katapult、固件、`[mcu] baud` 三处统一 |
| J17 接上后 Pi 不启动 | 把 J17 的 +5V 接到了 Pi | 只接 GND/TX/RX，+5V 悬空 |
| WiFi 模块抢串口 | 板上 ROBIN-WIFI 还在 J17 | 拔掉模块，或把 `EN` 拉低 |
| 屏白屏/乱码 | 屏固件/线序/5V | 重刷 `20240129.tft`；核黑5V/红GND/绿RX/黄TX；量 5V |

---

## 七、升级与回滚

**升级**：`sudo bash deploy/flash.sh --built`

**回滚（Klipper 版本）**：`flashtool` 刷上一版 `klipper.bin`（同样 16 KiB / 250000）即可。

**回原厂 Marlin**：⚠️ 原厂 bootloader 已被 Katapult 覆盖，**本仓库不含官方固件**。
需要：把 Katapult 重编成 **32 KiB 偏移** → 官方固件写到 **`0x08008000`**，然后 SWD 写入。
所以：**先备份官方固件 bin，再动手改板。**

---

## 八、产物校验（SHA256）

| 文件 | 大小 | SHA256 |
|---|---:|---|
| `artifacts/katapult_F401_USART2_J17.bin` | 2,286 | `bc235d64f6dcd6844d08f5077fda5b5e5bce05558070387d99318ef3b0d93465` |
| `artifacts/klipper_F401_USART2_J17_bridge.bin` | 35,864 | `54c573d11df2c7a47be8247d2541a9bf7152d121596efecd1e910c57df957e86` |
| `artifacts/20240129.tft` | 6,638,240 | `cb2bda95dbfd4cb8caad1e0cf3ef3e708177a9f3c66dcf2e64b9d28a646b9567` |

---

## 九、许可与致谢

- 本仓库：**GNU GPL v3.0**（见 [LICENSE](LICENSE)）。包含 Klipper 派生代码，必须保持 GPL。
- 基于并感谢：
  - [Klipper](https://github.com/Klipper3d/klipper)（Kevin O'Connor，GPL-3.0）
  - [Katapult](https://github.com/Arksine/katapult)（Arksine，GPL-3.0）
  - [KlipperLCD](https://github.com/joakimtoe/KlipperLCD)（joakimtoe，GPL-3.0）及其屏幕固件 `20240129.tft`
  - Elegoo 官方原理图 `ZNP_Robin_Nano_DW_V2.2_SCH.pdf`
- 免责：改机有风险（覆盖原厂引导器、损坏主板/屏幕）。请自行备份官方固件并承担风险。
