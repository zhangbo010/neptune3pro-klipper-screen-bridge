import getopt
import sys
import time
import base64
import subprocess
from threading import Thread
from datetime import timedelta

from printer import PrinterData
from lcd import LCD, _printerData

SELECTED_WIFI_SSID = None
SCANNED_WIFI_LIST = []


def is_ascii_ssid(s):
    try:
        s.encode("ascii")
        return True
    except UnicodeEncodeError:
        return False


def get_wifi_and_ip():
    ip_str = "No IP"
    ssid_str = ""
    try:
        out = subprocess.check_output(["ip", "-4", "-o", "addr", "show"], text=True, timeout=2)
        ips = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[1] != "lo":
                ip = parts[3].split("/")[0]
                ips.append(ip)
        if ips:
            ip_str = ips[0]
    except Exception:
        pass
    try:
        out = subprocess.check_output(
            ["nmcli", "-t", "-f", "TYPE,NAME,DEVICE", "connection", "show", "--active"],
            text=True,
            timeout=2,
        )
        for line in out.splitlines():
            cols = line.split(":")
            if len(cols) >= 2 and "wireless" in cols[0]:
                ssid_str = cols[1]
                break
    except Exception:
        pass
    return ip_str, ssid_str


def scan_wifi_networks(rescan="auto"):
    global SCANNED_WIFI_LIST
    nets = []
    seen = set()
    try:
        out = subprocess.check_output(
            ["sudo", "-n", "nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL", "dev", "wifi", "list", "--rescan", rescan],
            text=True,
            timeout=12,
        )
        for line in out.splitlines():
            cols = line.split(":")
            if len(cols) >= 3:
                in_use = cols[0].strip() == "*"
                ssid = cols[1].strip()
                sig = cols[2].strip()
                # Filter out non-ASCII SSIDs so TJC screen font never garbles
                if ssid and ssid not in seen and is_ascii_ssid(ssid):
                    seen.add(ssid)
                    nets.append((ssid, sig, in_use))
    except Exception as e:
        print("WiFi scan error:", e)
    SCANNED_WIFI_LIST = [n[0] for n in nets]
    return nets


def render_wifi_panel(lcd, rescan="auto", status_line=None, switch_to_console=False):
    ip_str, ssid_str = get_wifi_and_ip()
    nets = scan_wifi_networks(rescan=rescan)

    # Populate dropdown (macro.cb0) with clean ASCII SSIDs + RESCAN
    dropdown_items = ["[RESCAN_WIFI]"]
    for ssid, sig, in_use in nets[:12]:
        dropdown_items.append(ssid)
    lcd.write_macros(dropdown_items)

    # Build a single multi-line string and write it atomically to console.slt0.txt (zero flicker!)
    lines = []
    lines.append("WiFi: %s | IP: %s" % (ssid_str or "Disconnected", ip_str))
    if SELECTED_WIFI_SSID:
        lines.append("Target: [%s] -> Tap input box & type PWD" % SELECTED_WIFI_SSID)
    else:
        lines.append("1.Tap Macro to pick WiFi  2.Type Password")
    if status_line:
        lines.append(">> %s" % status_line)
    lines.append("------------------------------------")
    for idx, (ssid, sig, in_use) in enumerate(nets[:7]):
        mark = "*" if in_use else " "
        lines.append("%s[%d] %s (%s%%)" % (mark, idx + 1, ssid, sig))

    full_text = "\r\n".join(lines).replace('"', "'")
    lcd.write('console.buf.txt="%s"' % full_text)
    lcd.write("console.slt0.txt=console.buf.txt")

    if switch_to_console:
        lcd.write("page console")
        lcd.write("console.t0.txt=\"\"")


def handle_wifi_input(raw_cmd, lcd):
    global SELECTED_WIFI_SSID, SCANNED_WIFI_LIST
    text = raw_cmd.strip()
    if not text:
        return

    upper = text.upper()

    # 1. Rescan trigger
    if upper in ("[RESCAN_WIFI]", "WIFI_SCAN", "SCAN", "WIFI", "WIFI_STATUS"):
        lcd.write('console.buf.txt="Scanning WiFi networks, please wait..."')
        lcd.write("console.slt0.txt=console.buf.txt")
        lcd.write("page console")
        Thread(
            target=lambda: render_wifi_panel(
                lcd,
                rescan="yes",
                status_line="Scan done! Pick WiFi in Macro or type: <No> <PWD>",
                switch_to_console=True,
            ),
            daemon=True,
        ).start()
        return

    # 2. If user selected an SSID from the Macro dropdown list -> auto jump back to Console!
    if text in SCANNED_WIFI_LIST:
        SELECTED_WIFI_SSID = text
        render_wifi_panel(
            lcd,
            rescan="no",
            status_line="Selected [%s]! Tap input box below & enter password." % SELECTED_WIFI_SSID,
            switch_to_console=True,
        )
        return

    # 3. Direct "WIFI <SSID> <PASSWORD>" or "<No> <PASSWORD>" format
    parts = text.split()
    if len(parts) >= 2 and parts[0].upper() == "WIFI":
        target_ssid = parts[1]
        if target_ssid.isdigit() and 1 <= int(target_ssid) <= len(SCANNED_WIFI_LIST):
            target_ssid = SCANNED_WIFI_LIST[int(target_ssid) - 1]
        password = " ".join(parts[2:]) if len(parts) >= 3 else ""
        SELECTED_WIFI_SSID = target_ssid
        _connect_wifi_async(lcd, target_ssid, password)
        return

    # 4. "<index> <password>" or "<SSID> <password>" in one step
    if len(parts) == 2 and parts[0].isdigit() and 1 <= int(parts[0]) <= len(SCANNED_WIFI_LIST):
        target_ssid = SCANNED_WIFI_LIST[int(parts[0]) - 1]
        SELECTED_WIFI_SSID = target_ssid
        _connect_wifi_async(lcd, target_ssid, parts[1])
        return
    elif len(parts) == 2 and parts[0] in SCANNED_WIFI_LIST:
        SELECTED_WIFI_SSID = parts[0]
        _connect_wifi_async(lcd, parts[0], parts[1])
        return

    # 5. If an SSID is already selected, treat input directly as the WiFi password!
    if SELECTED_WIFI_SSID:
        password = text
        _connect_wifi_async(lcd, SELECTED_WIFI_SSID, password)
        return

    # Otherwise, treat single word as SSID selection and jump to console
    SELECTED_WIFI_SSID = text
    render_wifi_panel(
        lcd,
        rescan="no",
        status_line="Selected [%s]! Now type password & send." % SELECTED_WIFI_SSID,
        switch_to_console=True,
    )


def _connect_wifi_async(lcd, ssid, password):
    old_ip, old_ssid = get_wifi_and_ip()
    lcd.write('console.buf.txt="Connecting to [%s] ...\\r\\nPlease wait up to 15s..."' % ssid)
    lcd.write("console.slt0.txt=console.buf.txt")
    lcd.write("page console")
    lcd.write("console.t0.txt=\"\"")

    def _worker():
        try:
            # Remove stale profile with same SSID first so wrong old password doesn't interfere
            subprocess.run(["sudo", "-n", "nmcli", "connection", "delete", ssid], capture_output=True, timeout=5)
            cmd = ["sudo", "-n", "nmcli", "-w", "15", "dev", "wifi", "connect", ssid]
            if password:
                cmd += ["password", password]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
            ip_str, ssid_now = get_wifi_and_ip()
            if res.returncode == 0 and ssid_now == ssid:
                lcd.write('information.sversion.txt="%s (%s)"' % (ip_str, ssid_now))
                render_wifi_panel(
                    lcd,
                    rescan="no",
                    status_line="OK! Connected to %s (%s)" % (ssid_now, ip_str),
                    switch_to_console=True,
                )
            else:
                # If connection failed and WiFi dropped, auto-reconnect previous working SSID
                if not ssid_now and old_ssid:
                    subprocess.run(["sudo", "-n", "nmcli", "-w", "10", "connection", "up", old_ssid], capture_output=True, timeout=12)
                ip_str, ssid_now = get_wifi_and_ip()
                lcd.write('information.sversion.txt="%s (%s)"' % (ip_str, ssid_now))
                err = (res.stderr or res.stdout).strip().replace("\n", " ")
                if "Secrets were required" in err or "password" in err.lower():
                    msg = "Wrong password for [%s]! Kept [%s]" % (ssid, ssid_now or "offline")
                else:
                    msg = "Connect [%s] failed! Kept [%s]" % (ssid, ssid_now or "offline")
                render_wifi_panel(
                    lcd,
                    rescan="no",
                    status_line=msg,
                    switch_to_console=True,
                )
        except Exception as e:
            render_wifi_panel(lcd, rescan="no", status_line="ERROR: %s" % str(e)[:40], switch_to_console=True)

    Thread(target=_worker, daemon=True).start()


class KlipperLCD:
    def __init__(self):
        self.lcd = LCD("/tmp/ttyTJC", callback=self.lcd_callback)
        self.lcd.reinit_callback = self.on_screen_reconnected
        self.lcd.start()
        self.printer = PrinterData(
            "XXXXXX",
            URL=("127.0.0.1"),
            klippy_sock="/home/klipper/printer_data/comms/klippy.sock",
            callback=self.printer_callback,
        )
        self.running = False
        self.wait_probe = False
        self.thumbnail_inprogress = False
        self._last_ver_ip = None
        self._last_reinit_ts = 0
        self._tick_count = 0

        progress_bar = 1
        while self.printer.update_variable() == False:
            progress_bar += 5
            self.lcd.boot_progress(progress_bar)
            time.sleep(1)

        self.printer.init_Webservices()
        self._web_initialized = True
        self.on_screen_reconnected(force_main=True)

    def on_screen_reconnected(self, force_main=False):
        if not getattr(self, "_web_initialized", False):
            return
        now = time.time()
        if not force_main and (now - getattr(self, "_last_reinit_ts", 0) < 1.5):
            return
        self._last_reinit_ts = now
        try:
            print("Re-initializing TJC screen UI after hotplug/reset...")
            time.sleep(0.2)
            # Send empty terminator first to flush any partial command on screen side
            self.lcd.write("")
            self.lcd.write(b"com_star")
            self.lcd.write(b"main.va0.val=1")
            ip_str, ssid_str = get_wifi_and_ip()
            ver_ip = "%s (%s)" % (ip_str, ssid_str) if ssid_str else "%s | %s" % (ip_str, getattr(self.printer, "SHORT_BUILD_VERSION", "Klipper"))
            self._last_ver_ip = ver_ip
            self.lcd.write('information.size.txt="%s"' % getattr(self.printer, "MACHINE_SIZE", "235x234x280"))
            self.lcd.write('information.sversion.txt="%s"' % ver_ip)
            render_wifi_panel(self.lcd, rescan="no")
            state = self.printer.getState()
            if state in ("printing", "paused", "pausing"):
                self.lcd.write("page printpause")
            else:
                self.lcd.write("page main")
            # Force immediate temperature write to main page
            try:
                hotend = self.printer.thermalManager["temp_hotend"][0]["celsius"]
                hotend_t = self.printer.thermalManager["temp_hotend"][0]["target"]
                bed = self.printer.thermalManager["temp_bed"]["celsius"]
                bed_t = self.printer.thermalManager["temp_bed"]["target"]
                self.lcd.write('main.nozzletemp.txt="%d / %d"' % (hotend, hotend_t))
                self.lcd.write('main.bedtemp.txt="%d / %d"' % (bed, bed_t))
            except Exception:
                pass
            self.lcd.printer.hotend = None
            self.lcd.printer.bed = None
            print("TJC screen UI re-initialized -> page main")
        except Exception as e:
            print("on_screen_reconnected err:", e)

    def start(self):
        print("KlipperLCD start")
        self.running = True
        Thread(target=self.periodic_update).start()

    def periodic_update(self):
        while self.running:
            if self.wait_probe:
                print("Zpos=%f, Zoff=%f" % (self.printer.current_position.z, self.printer.BABY_Z_VAR))
                if self.printer.ishomed():
                    self.wait_probe = False
                    print("IsHomed")
                    self.lcd.probe_mode_start()

            self.printer.update_variable()
            data = _printerData()
            data.hotend_target = self.printer.thermalManager["temp_hotend"][0]["target"]
            data.hotend = self.printer.thermalManager["temp_hotend"][0]["celsius"]
            data.bed_target = self.printer.thermalManager["temp_bed"]["target"]
            data.bed = self.printer.thermalManager["temp_bed"]["celsius"]
            data.state = self.printer.getState()
            data.percent = self.printer.getPercent()
            data.duration = self.printer.duration()
            data.remaining = self.printer.remain()
            data.feedrate = self.printer.print_speed
            data.flowrate = self.printer.flow_percentage
            data.fan = self.printer.thermalManager["fan_speed"][0]
            data.x_pos = self.printer.current_position.x
            data.y_pos = self.printer.current_position.y
            data.z_pos = self.printer.current_position.z
            data.z_offset = self.printer.BABY_Z_VAR
            data.file_name = self.printer.file_name
            data.max_velocity = self.printer.max_velocity
            data.max_accel = self.printer.max_accel
            data.max_accel_to_decel = self.printer.max_accel_to_decel
            data.square_corner_velocity = self.printer.square_corner_velocity

            self.lcd.data_update(data)

            self._tick_count = getattr(self, "_tick_count", 0) + 1
            if self._tick_count % 2 == 0:
                try:
                    hotend = self.printer.thermalManager["temp_hotend"][0]["celsius"]
                    hotend_t = self.printer.thermalManager["temp_hotend"][0]["target"]
                    bed = self.printer.thermalManager["temp_bed"]["celsius"]
                    bed_t = self.printer.thermalManager["temp_bed"]["target"]
                    self.lcd.write('main.nozzletemp.txt="%d / %d"' % (hotend, hotend_t))
                    self.lcd.write('main.bedtemp.txt="%d / %d"' % (bed, bed_t))
                except Exception:
                    pass

            try:
                ip_str, ssid_str = get_wifi_and_ip()
                ver_ip = "%s (%s)" % (ip_str, ssid_str) if ssid_str else ip_str
                if self._last_ver_ip != ver_ip:
                    self._last_ver_ip = ver_ip
                    self.lcd.write('information.sversion.txt="%s"' % ver_ip)
            except Exception:
                pass

            time.sleep(2)

    def printer_callback(self, data, data_type):
        pass

    def show_thumbnail(self):
        if self.printer.file_path and (self.printer.file_name or self.lcd.files[self.lcd.selected_file]):
            file_name = ""
            if self.lcd.files:
                file_name = self.lcd.files[self.lcd.selected_file]
            elif self.printer.file_name:
                file_name = self.printer.file_name
            else:
                print("ERROR: gcode file not known")

            file = self.printer.file_path + "/" + file_name

            print(file)
            f = open(file, "r")
            if not f:
                f.close()
                print("File could not be opened: %s" % file)
                return
            buf = f.readlines()
            if not f:
                f.close()
                print("File could not be read")
                return

            f.close()
            thumbnail_found = False
            b64 = ""

            for line in buf:
                if "thumbnail begin" in line:
                    thumbnail_found = True
                elif "thumbnail end" in line:
                    thumbnail_found = False
                    break
                elif thumbnail_found:
                    b64 += line.strip(" \t\n\r;")

            if len(b64):
                img = base64.b64decode(b64)
                self.lcd.write_thumbnail(img)
            else:
                self.lcd.clear_thumbnail()
                print("Aborting thumbnail, no image found")
        else:
            print("File path or name to gcode-files missing")

        self.thumbnail_inprogress = False

    def lcd_callback(self, evt, data=None):
        if evt == self.lcd.evt.HOME:
            self.printer.home(data)
        elif evt == self.lcd.evt.MOVE_X:
            self.printer.moveRelative("X", data, 4000)
        elif evt == self.lcd.evt.MOVE_Y:
            self.printer.moveRelative("Y", data, 4000)
        elif evt == self.lcd.evt.MOVE_Z:
            self.printer.moveRelative("Z", data, 600)
        elif evt == self.lcd.evt.MOVE_E:
            print(data)
            self.printer.moveRelative("E", data[0], data[1])
        elif evt == self.lcd.evt.Z_OFFSET:
            self.printer.setZOffset(data)
        elif evt == self.lcd.evt.NOZZLE:
            self.printer.setExtTemp(data)
        elif evt == self.lcd.evt.BED:
            self.printer.setBedTemp(data)
        elif evt == self.lcd.evt.FILES:
            files = self.printer.GetFiles(True)
            return files
        elif evt == self.lcd.evt.PRINT_START:
            self.printer.openAndPrintFile(data)
            if self.thumbnail_inprogress == False:
                self.thumbnail_inprogress = True
        elif evt == self.lcd.evt.THUMBNAIL:
            if self.thumbnail_inprogress == False:
                self.thumbnail_inprogress = True
                Thread(target=self.show_thumbnail).start()
        elif evt == self.lcd.evt.PRINT_STATUS:
            pass
        elif evt == self.lcd.evt.PRINT_STOP:
            self.printer.cancel_job()
        elif evt == self.lcd.evt.PRINT_PAUSE:
            self.printer.pause_job()
        elif evt == self.lcd.evt.PRINT_RESUME:
            self.printer.resume_job()
        elif evt == self.lcd.evt.PRINT_SPEED:
            self.printer.set_print_speed(data)
        elif evt == self.lcd.evt.FLOW:
            self.printer.set_flow(data)
        elif evt == self.lcd.evt.PROBE:
            if data == None:
                self.printer.probe_calibrate()
                self.wait_probe = True
            else:
                self.printer.probe_adjust(data)
        elif evt == self.lcd.evt.PROBE_COMPLETE:
            self.wait_probe = False
            print("Save settings!")
            self.printer.sendGCode("ACCEPT")
            self.printer.sendGCode("G1 F1000 Z15.0")
            print("Calibrate!")
            self.printer.sendGCode("BED_MESH_CALIBRATE PROFILE=default METHOD=automatic")
        elif evt == self.lcd.evt.PROBE_BACK:
            print("BACK!")
            self.printer.sendGCode("ACCEPT")
            self.printer.sendGCode("G1 F1000 Z15.0")
            self.printer.sendGCode("SAVE_CONFIG")
        elif evt == self.lcd.evt.BED_MESH:
            pass
        elif evt == self.lcd.evt.LIGHT:
            self.printer.set_led(data)
        elif evt == self.lcd.evt.FAN:
            self.printer.set_fan(data)
        elif evt == self.lcd.evt.MOTOR_OFF:
            self.printer.sendGCode("M18")
        elif evt == self.lcd.evt.ACCEL:
            self.printer.sendGCode("SET_VELOCITY_LIMIT ACCEL=%d" % data)
        elif evt == self.lcd.evt.ACCEL_TO_DECEL:
            self.printer.sendGCode("SET_VELOCITY_LIMIT ACCEL_TO_DECEL=%d" % data)
        elif evt == self.lcd.evt.VELOCITY:
            self.printer.sendGCode("SET_VELOCITY_LIMIT VELOCITY=%d" % data)
        elif evt == self.lcd.evt.SQUARE_CORNER_VELOCITY:
            print("SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY=%.1f" % data)
            self.printer.sendGCode("SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY=%.1f" % data)
        elif evt == self.lcd.evt.CONSOLE:
            handle_wifi_input(data, self.lcd)
        else:
            print("lcd_callback event not recognised %d" % evt)


if __name__ == "__main__":
    x = KlipperLCD()
    x.start()
