# Host-side UART bridge for an MCU USART6 serial display.
#
# Exposes a PTY. Point KlipperLCD at that path; do not change its protocol.
#
# This file may be distributed under the terms of the GNU GPLv3 license.

import logging, os, termios
import util

# Klipper MESSAGE_MAX is 64 bytes including header/trailer, so a %*s
# payload of 64 does not fit. 48 is safely under the wire limit.
PAYLOAD_MAX = 48
HOST_TX_LIMIT = 8192
POLL_INTERVAL = 0.010
RX_INFLIGHT_TIMEOUT = 0.50

def _set_raw(fd):
    attrs = termios.tcgetattr(fd)
    attrs[0] &= ~(termios.BRKINT | termios.ICRNL | termios.INPCK
                  | termios.ISTRIP | termios.IXON)
    attrs[1] &= ~termios.OPOST
    attrs[2] = (attrs[2] & ~(termios.CSIZE | termios.PARENB)) | termios.CS8
    attrs[3] &= ~(termios.ECHO | termios.ECHONL | termios.ICANON
                  | termios.IEXTEN | termios.ISIG)
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

class ScreenBridge:
    def __init__(self, config):
        self.printer = config.get_printer()
        self._config_error = config.error
        self.reactor = self.printer.get_reactor()
        self.pty_path = config.get('pty', '/tmp/ttyTJC')
        self.baud = config.getint('baud', 115200, minval=1200, maxval=4500000)
        self.mcu = self.printer.lookup_object('mcu')
        self.cmd_tx = self.cmd_rx = None
        self.cmd_cfg = self.cmd_reset = self.cmd_stats = None
        self.pending_tx = bytearray()
        self.host_tx_dropped = 0
        self.host_pty_dropped = 0
        self.mcu_rx_dropped = 0
        self.mcu_tx_dropped = 0
        self._rx_inflight = False
        self._rx_sent_time = 0.
        self.master_fd, self.slave_fd = None, None
        self.fd_handle = None
        self.poll_timer = None
        self._open_pty()
        self._register_responses()
        self.mcu.register_config_callback(self._build_config)
        self.printer.register_event_handler("klippy:connect",
                                            self._handle_connect)
        self.printer.register_event_handler("klippy:ready",
                                            self._handle_ready)
        self.printer.register_event_handler("klippy:disconnect",
                                            self._handle_disconnect)
        self.printer.register_event_handler("klippy:shutdown",
                                            self._handle_disconnect)

    def _open_pty(self):
        self.master_fd, self.slave_fd = os.openpty()
        try:
            os.unlink(self.pty_path)
        except OSError:
            pass
        slave_name = os.ttyname(self.slave_fd)
        os.chmod(slave_name, 0o666)
        os.symlink(slave_name, self.pty_path)
        util.set_nonblock(self.master_fd)
        _set_raw(self.master_fd)
        _set_raw(self.slave_fd)
        self.fd_handle = self.reactor.register_fd(
            self.master_fd, self._handle_read)
        logging.info("screen_bridge: PTY ready at %s (slave %s, baud %d)",
                     self.pty_path, slave_name, self.baud)

    def _register_responses(self):
        # Older Klipper: register_response(cb, name)
        # Current Klipper: register_serial_response(cb, full_format)
        if hasattr(self.mcu, 'register_response'):
            self.mcu.register_response(self._handle_bridge_data, 'bridge_data')
            self.mcu.register_response(self._handle_bridge_stats,
                                       'bridge_stats')
        else:
            self.mcu.register_serial_response(
                self._handle_bridge_data, 'bridge_data data=%*s')
            self.mcu.register_serial_response(
                self._handle_bridge_stats,
                'bridge_stats rx_dropped=%u tx_dropped=%u')

    def _build_config(self):
        cq = self.mcu.alloc_command_queue()
        try:
            self.cmd_tx = self.mcu.lookup_command("bridge_tx data=%*s", cq=cq)
            self.cmd_rx = self.mcu.lookup_command("bridge_rx max=%c", cq=cq)
            self.cmd_cfg = self.mcu.lookup_command(
                "bridge_config baud=%u", cq=cq)
            self.cmd_reset = self.mcu.lookup_command("bridge_reset", cq=cq)
            self.cmd_stats = self.mcu.lookup_command(
                "bridge_get_stats", cq=cq)
        except Exception:
            raise self._config_error(
                "MCU firmware does not include screen_bridge. "
                "Enable WANT_SCREEN_BRIDGE in menuconfig and flash again.")

    def _handle_connect(self):
        if self.cmd_reset is not None:
            self.cmd_reset.send([])
        if self.cmd_cfg is not None:
            self.cmd_cfg.send([self.baud])
        self._flush_tx()

    def _handle_ready(self):
        if self.poll_timer is None:
            self.poll_timer = self.reactor.register_timer(self._poll_rx)
        self.reactor.update_timer(self.poll_timer, self.reactor.NOW)

    def _handle_disconnect(self):
        if self.poll_timer is not None:
            self.reactor.update_timer(self.poll_timer, self.reactor.NEVER)
        self._rx_inflight = False
        self.pending_tx.clear()

    def _handle_read(self, eventtime):
        if self.master_fd is None:
            return
        try:
            data = os.read(self.master_fd, 4096)
        except OSError:
            return
        if not data:
            return
        if len(self.pending_tx) + len(data) > HOST_TX_LIMIT:
            self.host_tx_dropped += len(data)
            return
        self.pending_tx.extend(data)
        self._flush_tx()

    def _flush_tx(self):
        if self.cmd_tx is None or not self.pending_tx:
            return
        while self.pending_tx:
            chunk = bytes(self.pending_tx[:PAYLOAD_MAX])
            del self.pending_tx[:PAYLOAD_MAX]
            self.cmd_tx.send([chunk])

    def _poll_rx(self, eventtime):
        if self.printer.is_shutdown() or self.cmd_rx is None:
            return self.reactor.NEVER
        if self._rx_inflight:
            if eventtime - self._rx_sent_time < RX_INFLIGHT_TIMEOUT:
                return eventtime + POLL_INTERVAL
            self._rx_inflight = False
        self._rx_inflight = True
        self._rx_sent_time = eventtime
        try:
            self.cmd_rx.send([PAYLOAD_MAX])
        except Exception:
            self._rx_inflight = False
        return eventtime + POLL_INTERVAL

    def _handle_bridge_data(self, params):
        # Invoked from the MCU serial thread; only touch PTY + counters.
        self._rx_inflight = False
        data = params.get('data') or b''
        if not isinstance(data, (bytes, bytearray)):
            data = bytearray(data)
        if data and self.master_fd is not None:
            try:
                os.write(self.master_fd, data)
            except OSError:
                self.host_pty_dropped += len(data)

    def _handle_bridge_stats(self, params):
        self.mcu_rx_dropped = params.get('rx_dropped', 0)
        self.mcu_tx_dropped = params.get('tx_dropped', 0)

    def stats(self, eventtime):
        if self.cmd_stats is not None and not self.printer.is_shutdown():
            try:
                self.cmd_stats.send([])
            except Exception:
                pass
        return False, (
            "screen_bridge pty=%s host_tx_dropped=%d host_pty_dropped=%d"
            " mcu_rx_dropped=%d mcu_tx_dropped=%d queued=%d"
            % (self.pty_path, self.host_tx_dropped, self.host_pty_dropped,
               self.mcu_rx_dropped, self.mcu_tx_dropped, len(self.pending_tx)))

    def get_status(self, eventtime):
        return {
            'pty': self.pty_path,
            'baud': self.baud,
            'host_tx_dropped': self.host_tx_dropped,
            'host_pty_dropped': self.host_pty_dropped,
            'mcu_rx_dropped': self.mcu_rx_dropped,
            'mcu_tx_dropped': self.mcu_tx_dropped,
            'queued': len(self.pending_tx),
        }

def load_config(config):
    return ScreenBridge(config)
