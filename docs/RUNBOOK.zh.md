# 海王星 3 Pro 无损改 Klipper —— 完整流程（编译 → 烧录 → 配置）

> **权威版本：2026-11-11 实测打通版**（Katapult `@0x08000000` + Klipper `@0x08004000`）
> 机型：Elegoo Neptune 3 Pro / 主板 ZNP Robin Nano_DW V2.2 / STM32F401RCT6 / 8 MHz 晶振
> 上位机：MKS Pi 1.1（Armbian，UART0 = `/dev/ttyS0`）
> 屏幕：原厂陶晶驰 TJC4827X243_011（4P4C 电话线，主板 J33）
> 归档：飞牛 `artifacts/`
> 本机副本：`./`

---

## 0. 三个地址、两个波特率（先背下来）

| 项 | 值 | 说明 |
|---|---|---|
| Katapult 起始 | `0x08000000` | 占 16 KiB 引导区（bin 约 2.3 KB） |
| Klipper 起始 | **`0x08004000`** | **16 KiB 偏移**，不是 32 KiB |
| 主机链路 | **USART2 PA3(RX)/PA2(TX)**，J17，**250000** | 到 Pi `/dev/ttyS0` |
| 屏链路 | **USART6 PA12(RX)/PA11(TX)**，J33，**115200** | 原电话线直插，MCU 桥接 |

⚠ 三个致命坑，先看再动手：

- **坑 1：不要把 Klipper 烧到 `0x08000000`** —— 引导器就没了，之后只能 SWD/BOOT0 救。
- **坑 2：不要把 `USART6` 当成 `PC7/PC6`** —— 那是 `Z_STEP`/`E0_EN`（挤出机使能），会抢运动引脚。
  STM32F401 的 USART6 有两套 AF8 引脚：`PA12/PA11`（本机屏口）和 `PC7/PC6`（已被运动占用）。
- **坑 3：不要混用 32 KiB/500000 的旧产物** —— 旧版 `firmware/ZNP_ROBIN_NANO.bin`（35,816 B，Reset `0x08008295`）
  是 32 KiB/500000 的废弃版本；最终版是 **35,864 B，Reset `0x08004271`**（16 KiB/250000）。

---

## 1. 硬件接线

### 1.1 主板 J17（原 WiFi 模块座）↔ MKS Pi UART0

| J17 | 定义 | 接到 Pi |
|---|---|---|
| 1 | +5V（模块供电输出） | **悬空，严禁接** |
| 2 | GND | Pi GND |
| 3 | TXD2（PA2，MCU 发） | Pi **RX**（UART0_RX / GPIO15 / 物理 10 脚） |
| 4 | RXD2（PA3，MCU 收） | Pi **TX**（UART0_TX / GPIO14 / 物理 8 脚） |

- 3.3V TTL 直连，TX/RX 交叉；**断电插拔**。
- **板上 WiFi 模块（ROBIN-WIFI，M1）必须拔掉**，否则它会并联在 USART2 上抢串口；不拔就把它的 `EN` 拉低。
- Pi 与主板各自独立供电，J17 的 +5V 是主板输出，接上就是往 Pi 灌 5V。

### 1.2 主板 J33（4P4C 电话线座）↔ 原厂屏

- 原厂电话线**直插 J33**，不剪线、不加转接板。
- 物理引脚（原理图 + 实测）：`J33.3 = TXD6 → PA11`，`J33.4 = RXD6 → PA12`；115200 8N1。
- 屏的 5V 由 J33 的 1 脚供给（原厂线序：黑=5V、红=GND、绿=RX、黄=TX；按针位核，别只信颜色）。

### 1.3 上电顺序
打印机 24V → Pi 启动（约 40 s）→ Klipper → Moonraker → KlipperLCD（最后起）。

---

## 2. 上位机准备（MKS Pi 1.1）

```bash
# 1) UART0 必须可用，且不能被控制台占用
ls -l /dev/ttyS0
cat /proc/cmdline | tr ' ' '\n' | grep console    # 控制台应为 ttyS2，不能是 ttyS0
systemctl status serial-getty@ttyS0               # 必须 inactive
stty -F /dev/ttyS0 -a | head -1                   # 能设 250000

# 2) Klipper / Moonraker / Mainsail（已装可跳过）
cd ~ && git clone https://github.com/dw-0/kiauh.git && ./kiauh/kiauh.sh
# 安装目录默认 /home/klipper/klipper；gcc-arm-none-eabi 必须装

# 3) 权限
sudo usermod -aG dialout klipper
```

> `/dev/ttyS0` 是 RK3328 的 UART0（`ff110000.serial`，16550A）。250000 是能整除其时钟的分频点，
> 实测 0 重传、0 丢包；**不要用 500000**（旧版踩过）。

---

## 3. 编译 Katapult（16 KiB 引导器，只需一次）

```bash
cd ~ && git clone https://github.com/Arksine/katapult.git
cd katapult && make menuconfig
```

| menuconfig 项 | 值 |
|---|---|
| Micro-controller Architecture | STMicroelectronics STM32 |
| Processor model | STM32F401 |
| Bootloader offset | **16KiB bootloader (0x8004000)** |
| Clock Reference | **8 MHz crystal** |
| Communication interface | **Serial (on USART2 PA3/PA2)** |
| Baud rate | **250000** |
| Support bootloader entry on rapid double click of reset button | **y**（默认） |
| Enable bootloader entry on button | n |

```bash
make
# 产物：out/katapult.bin（最终版 2,286 B）、out/deployer.bin
grep -E 'FLASH_APPLICATION_ADDRESS|SERIAL_BAUD|STM32_SERIAL_USART2 |ENABLE_DOUBLE_RESET' out/autoconf.h
# 期望：0x8004000 / 250000 / 1 / 1
python3 - <<'PY'
import struct
d=open('out/katapult.bin','rb').read()
print(len(d), hex(struct.unpack('<I',d[4:8])[0]))   # 复位向量应为 0x08000xxx
PY
```

> 本机 `./katapult/out/` 里还是 11-10 的 32 KiB/500000 旧版（2,472 B），
> **不要拿它刷**；以本流程重编，或直接用归档里的 `artifacts/katapult_F401_USART2_J17.bin`（2,286 B）。

---

## 4. 编译 Klipper 应用固件（16 KiB + 屏桥接）

### 4.1 把桥接代码放进树里

```bash
cd ~/klipper
# 1) MCU 侧
cp ./src/klipper_bridge/screen_bridge.c \
   src/stm32/
# 2) 上位机侧
cp ./src/klipper_bridge/screen_bridge.py \
   klippy/extras/
```

`src/stm32/Makefile`：在 `src-$(CONFIG_SERIAL) += ...` 之后加一行
```make
src-$(CONFIG_WANT_SCREEN_BRIDGE) += stm32/screen_bridge.c
```

`src/stm32/Kconfig`：在文件末尾、`if MACH_STM32` 的最后一个 `endif` 之前插入
```kconfig
config WANT_SCREEN_BRIDGE
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
```

> 归档的 `.config` 里已经带 `CONFIG_WANT_SCREEN_BRIDGE=y` 和 `CONFIG_STM32_SCREEN_BRIDGE_BAUD=115200`，
> 但 **Kconfig/Makefile 的插入片段不在归档里**，重建时必须按上面补。

### 4.2 menuconfig

| 项 | 值 |
|---|---|
| Micro-controller Architecture | STMicroelectronics STM32 |
| Processor model | STM32F401 |
| Bootloader offset | **16KiB bootloader (0x8004000)** |
| Clock Reference | 8 MHz crystal |
| Communication interface | **Serial (on USART2 PA3/PA2)** |
| Enable extra low-level configuration options | **y** |
| Baud rate for serial port | **250000** |
| Serial screen UART bridge (USART6 PA12/PA11) | **y** |
| Screen bridge baud rate | **115200** |

### 4.3 编译与产物校验（不通过不烧）

```bash
make
cp out/klipper.bin out/ZNP_ROBIN_NANO.bin
xxd -l 8 out/ZNP_ROBIN_NANO.bin      # SP=0x20010000，Reset 必须是 0x08004xxx
grep -E 'FLASH_APPLICATION_ADDRESS|SERIAL_BAUD=|SCREEN_BRIDGE' out/autoconf.h
grep -E 'bridge_(tx|rx|config|reset|get_stats)' out/compile_time_request.txt
sha256sum out/ZNP_ROBIN_NANO.bin     # 最终版：54c573d1…df957e86，35,864 B
```

- `FLASH_APPLICATION_ADDRESS` 必须是 `0x8004000`。
- `CONFIG_SERIAL_BAUD` 必须是 `250000`。
- 编译请求表没有 `bridge_*` = 模块没编进去，别刷。

---

## 5. 烧录

### 5.1 首次 / 救砖：SWD（ST-Link）

**两个文件、两个地址，缺一不可：**

| 顺序 | 文件 | 地址 |
|---|---|---|
| 1 | `artifacts/katapult_F401_USART2_J17.bin` | `0x08000000` |
| 2 | `artifacts/klipper_F401_USART2_J17_bridge.bin` | `0x08004000` |

- 接线：J1 的 `3.3V / GND / SWDIO / SWCLK`（**本板 J1 没接 NRST**）。
- STM32CubeProgrammer 选 **Connect under reset**；若连不上（旧固件上电几毫秒跑飞，报 `TransferError 0x06`），
  用归档文档里的抢占法：复位瞬间把内核 halt 在复位向量，并写 `DBGMCU_CR=0x07` 锁住调试时钟，
  然后擦除 Sector 0~3、按上表双段写入、逐字节校验。
- 烧完**断电再上电**。

### 5.2 替代：BOOT0 + 芯片 ROM 引导器（不用 ST-Link）

1. **J10 跳线 1-2 短接**（1 针 = BOOT0/60 脚，2 针 = +3V3）；万用表量 J10-1 对 GND = **3.3V**。
2. 保持跳线，**断电再上电**（BOOT0 只在复位时采样）。
3. USB 数据线：主板 USB 口（CH340）→ Pi；认到 `/dev/ttyUSB0`。
4. 分两次写，**不要用 `-e` 整片擦**：

```bash
# 引导器（只擦 0x08000000 起的 16 KiB 扇区）
stm32flash -b 115200 -m 8e1 -w katapult_F401_USART2_J17.bin -S 0x08000000 -v /dev/ttyUSB0
# 应用（只擦 0x08004000 之后的扇区，保留引导器）
stm32flash -b 115200 -m 8e1 -w klipper_F401_USART2_J17_bridge.bin -S 0x08004000 -v /dev/ttyUSB0
```
5. 拔 J10 → 断电重上电。

> CH340 的 DTR# 经 C33 接 RESET，打开串口会给一次复位脉冲；BOOT0 已拉高时这反而正常（重新进 ROM）。

### 5.3 日常在线升级（Katapult 在位时，免拆机）

```bash
sudo systemctl stop klipper
python3 ~/katapult/scripts/flashtool.py -d /dev/ttyS0 -b 250000 -r
sleep 0.5
python3 ~/katapult/scripts/flashtool.py -d /dev/ttyS0 -b 250000 -f ~/klipper/out/klipper.bin
sudo systemctl start klipper
sudo systemctl restart KlipperLCD
```

- `-r` 请求进引导器；不行就 **J1 5(RESET)-6(GND) 快速短接两次**（双击复位窗口 500 ms）或断电重上电。
- 刷前核对 flashtool 报的 SHA 与你本机 `sha1sum` 一致；**SHA 对不上就是刷错文件**。

### 5.4 刷后握手验证（不接屏也能做）

```bash
cat > /tmp/t.cfg <<'EOF'
[mcu]
serial: /dev/ttyS0
baud: 250000
restart_method: command
[printer]
kinematics: none
max_velocity: 1
max_accel: 1
EOF
timeout 40 ~/klippy-env/bin/python ~/klipper/klippy/klippy.py /tmp/t.cfg -l /tmp/t.log
grep -E 'mcu_version|Klipper state|Timeout|Unable' /tmp/t.log
```
看到 `mcu_version` / `Klipper state: Ready` 才算链路通。

---

## 6. 配置

### 6.1 printer.cfg（最终版）

完整文件在 `final_20261111/src/config/printer.cfg`，核心段落：

```ini
[include mainsail.cfg]
[include plr.cfg]

[mcu]
serial: /dev/ttyS0
baud: 250000
restart_method: command

[screen_bridge]
pty: /tmp/ttyTJC
baud: 115200

[printer]
kinematics: cartesian
max_velocity: 300
max_accel: 3000
max_z_velocity: 15
max_z_accel: 100
square_corner_velocity: 5.0

[stepper_z]
step_pin: PC7
dir_pin: !PC9
enable_pin: !PC8
microsteps: 16
rotation_distance: 8
position_min: -2.0
position_max: 280
endstop_pin: PB4          # 本机 Z 限位开关；有 CR-Touch 的机器改用 probe:z_virtual_endstop
homing_speed: 8
second_homing_speed: 3
position_endstop: 0

[fan]
pin: PB2                  # 占位，供 KlipperLCD 读取

[heater_fan controller_fan]
pin: PB0                  # FAN1 电器仓风扇
heater: extruder
heater_temp: 50.0
fan_speed: 1.0

[heater_fan hotend_fan]
pin: PA7                  # FAN2 喉管风扇
heater: extruder
heater_temp: 50.0
fan_speed: 1.0
```

本机专属值（照抄归档，换机要重标）：`extruder rotation_distance: 7.53`、`nozzle_diameter: 0.600`、
`Z endstop: PB4`、`safe_z_home: 146.0, 95.5`。**探针与 bed_mesh 在归档里是注释掉的**；
如果这台机器装了 CR-Touch，取消 `[probe]`/`[bed_mesh]` 注释并把 Z 改成 `probe:z_virtual_endstop`。

### 6.2 KlipperLCD（含热插拔 + WiFi 面板）

```bash
cd ~ && git clone https://github.com/joakimtoe/KlipperLCD.git
cd KlipperLCD
# 用归档的增强版覆盖（支持 PTY 重建、0x00/0x1A/0x88 重初始化、WiFi 面板）
cp ./src/KlipperLCD/{main.py,lcd.py,printer.py,lib_col_pic.py} .
pip3 install pyserial --break-system-packages
python3 -m py_compile main.py lcd.py printer.py
```

- `main.py` 里 `LCD("/tmp/ttyTJC")`、`klippy_sock="/home/klipper/printer_data/comms/klippy.sock"`（归档版已改好）。
- WiFi 面板需要 `nmcli` 免密：
```bash
echo 'klipper ALL=(ALL) NOPASSWD: /usr/bin/nmcli' | sudo tee /etc/sudoers.d/klipper-nmcli
sudo chmod 440 /etc/sudoers.d/klipper-nmcli
```
- systemd：`final_20261111/src/KlipperLCD/KlipperLCD.service` → `/etc/systemd/system/`，
  `systemctl daemon-reload && systemctl enable --now KlipperLCD`。

屏幕操作：
- **Macro 页**：下拉框列出 `[RESCAN_WIFI]` + 信号最强的 WiFi → 选一个 → Send → 自动跳回 Console；
- **Console 页**：点输入框弹全键盘 → 输入密码 → Send → `nmcli` 连接；密码错会自动回退原网络。
- 中文 SSID 会被过滤（屏幕字库无中文），英文/数字 SSID 正常。

---

## 7. 上机验证清单

1. `cat /proc/tty/driver/serial`：`ttyS0` 的 tx/rx 在涨，无持续 `brk/oe`。
2. Klipper `state: ready`，`mcu_version` 与 `~/klipper` commit 对应。
3. `ls -l /tmp/ttyTJC` 存在（指向 `/dev/pts/N`）。
4. 屏亮、进主界面，温度/IP 与 Mainsail 一致。
5. **热插拔**：拔电话线 2 秒再插回，1–2 秒内自动回主界面（靠 0x00/0x1A/0x88 + 4 s 心跳）。
6. WiFi 面板：扫描、连接、密码错误回退各测一次。
7. `STEPPER_BUZZ STEPPER=stepper_x`（x/y/z/挤出机逐个），方向不对改 `dir_pin` 的 `!`。
8. `QUERY_ENDSTOPS` 手动触发 X/Y/Z；`G28` 首次手放急停。
9. `PID_CALIBRATE HEATER=extruder TARGET=200`、`HEATER=heater_bed TARGET=60` → `SAVE_CONFIG`。
10. 空跑 20×20 方块 → 第一层 → Benchy。

---

## 8. 故障排查

| 现象 | 根因 | 处理 |
|---|---|---|
| 屏完全没反应，Klipper 报 `Pin PC7 is reserved` | 桥接用了 `PC6/PC7`（Z_STEP/E0_EN） | 改用 `PA12/PA11`（USART6 AF8），重编 |
| 刷完 `Timeout on connect` | bin 是 32 KiB/500000 旧版 | 用 16 KiB/250000 版；`xxd` 看 Reset=`0x08004xxx` |
| Katapult 不应答 | 已跳应用 / 过了 500 ms 窗口 | `-r`；J1 5-6 双击复位；断电重上电 |
| ST-Link `TransferError 0x06` | 旧固件上电即跑飞，J1 无 NRST | Connect under reset + 复位瞬间 halt（归档文档的抢占法） |
| 屏卡在 boot 页 | 待机无数据、屏回 `0x1A` 被丢弃 | 用归档增强版 `lcd.py`/`main.py`（0x1A/0x88 重初始化 + 4 s 心跳） |
| 拔插屏后 KlipperLCD 断连 | PTY 在 Klipper 重启时被销毁 | 用归档 `screen_bridge.py`（disconnect/shutdown 保活 + inode 跟踪） |
| 主机串口丢包/重传 | 波特率不是 250000 | katapult、固件、`[mcu] baud` 三处统一 250000 |
| J17 接上后 Pi 不启动 | 把 J17 的 +5V 接到了 Pi | 只接 GND/TX/RX，+5V 悬空 |
| WiFi 模块抢串口 | 板上 ROBIN-WIFI 还在 J17 | 拔掉模块，或把模块 `EN` 拉低 |
| 屏白屏/乱码 | 屏固件/线序/5V | 重刷 `20240129.tft`；核黑5V/红GND/绿RX/黄TX；量 5V |

---

## 9. 回滚

- 现在板上是 **Katapult（16 KiB）+ Klipper（0x08004000）**，**原厂 bootloader 已被覆盖，且本机没有原厂 dump**。
- 回原厂 Marlin 需要：把 Katapult 重编成 **32 KiB 偏移**，官方固件写到 **0x08008000**；
  也就是“换引导器 + 换应用”两件事，不能只刷 app。
- 所以：**先备份官方固件 bin**（Elegoo 官网 SD 更新包），再继续实验。
- 日常回退 Klipper 版本：直接 `flashtool` 刷上一版 `klipper.bin`（16 KiB/250000）即可。

---

## 10. 最终产物与 SHA256

| 文件 | 大小 | SHA256 |
|---|---|---|
| `artifacts/katapult_F401_USART2_J17.bin` | 2,286 | `bc235d64…d93465` |
| `artifacts/klipper_F401_USART2_J17_bridge.bin` | 35,864 | `54c573d1…df957e86` |
| `src/klipper_bridge/screen_bridge.c` | 5,696 | `e9bddc0c…360020b` |
| `src/klipper_bridge/screen_bridge.py` | 7,986 | `92d1cf69…b84db8aa` |
| `artifacts/20240129.tft` | 6,638,240 | `cb2bda95…a646b9567` |

树内关键配置：`src/klipper_bridge/.config`（F401xc / 0x8004000 / USART2 / 250000 / WANT_SCREEN_BRIDGE / 115200）。
