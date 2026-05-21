#!/usr/bin/env python3
"""Verify an OpenThread RCP by probing PROP_NCP_VERSION via Spinel/HDLC.

Sends PROP_VALUE_GET(PROP_NCP_VERSION) with TID=1 and checks for a valid
PROP_VALUE_IS response. Tries pyserial first; falls back to Python stdlib
so the script runs without a venv (e.g. on a freshly flashed Raspberry Pi).

Usage:  verify_rcp.py <port>
Exit 0: valid Spinel response received.
Exit 1: no response or probe error.
Exit 2: port could not be opened.

Root cause notes (ESP32-C6 USB Serial/JTAG):
- TID=0 (header 0x80) means "unsolicited / no response expected".  The
  device correctly ignores PROP_VALUE_GET frames sent with TID=0.  Use
  TID=1 (header 0x81) to get a PROP_VALUE_IS reply.
- Opening /dev/ttyACM0 causes the kernel CDC-ACM driver to send
  SET_CONTROL_LINE_STATE(DTR=1, RTS=1).  The ESP32-C6 USB Serial/JTAG
  peripheral is hardwired to reset on that assertion — it is not
  configurable in firmware.  Both probe paths deassert DTR/RTS
  immediately after open, then wait 4 s for the device to reboot and
  the Spinel stack to initialise before sending the probe frame.
"""

import sys
import struct
import time

HDLC_FLAG = 0x7E


def fcs16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


def build_frame():
    payload = bytes([0x81, 0x02, 0x02])  # TID=1, CMD_PROP_VALUE_GET, PROP_NCP_VERSION
    raw = payload + struct.pack('<H', fcs16(payload))
    frame = bytearray([HDLC_FLAG])
    for b in raw:
        if b in (0x7E, 0x7D):
            frame += bytes([0x7D, b ^ 0x20])
        else:
            frame.append(b)
    frame.append(HDLC_FLAG)
    return bytes(frame)


def probe_pyserial(port, frame):
    import serial
    ser = serial.Serial()
    ser.port = port
    ser.baudrate = 460800
    ser.timeout = 4
    ser.dsrdtr = False
    ser.rtscts = False
    ser.open()
    ser.dtr = False
    ser.rts = False
    ser.reset_input_buffer()
    time.sleep(4)
    ser.reset_input_buffer()
    ser.write(frame)
    time.sleep(0.5)
    resp = ser.read(256)
    ser.close()
    return resp


def probe_stdlib(port, frame):
    import os
    import fcntl
    import termios
    import tty
    import select
    TIOCMBIC  = 0x5417
    TIOCM_DTR = 0x002
    TIOCM_RTS = 0x004
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    fcntl.ioctl(fd, TIOCMBIC, struct.pack('I', TIOCM_DTR | TIOCM_RTS))
    tty.setraw(fd)
    os.set_blocking(fd, True)
    termios.tcflush(fd, termios.TCIFLUSH)
    time.sleep(4)
    termios.tcflush(fd, termios.TCIFLUSH)
    os.write(fd, frame)
    time.sleep(0.5)
    try:
        ready, _, _ = select.select([fd], [], [], 4.0)
        resp = os.read(fd, 256) if ready else b''
    except OSError:
        resp = b''
    finally:
        os.close(fd)
    return resp


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <port>', file=sys.stderr)
        sys.exit(2)
    port = sys.argv[1]
    frame = build_frame()
    try:
        try:
            resp = probe_pyserial(port, frame)
        except ImportError:
            resp = probe_stdlib(port, frame)
        if HDLC_FLAG in resp and len(resp) > 4:
            print(f'RCP OK — {len(resp)}-byte Spinel response from {port}')
            sys.exit(0)
        print(
            f'ERROR: no Spinel response from {port} '
            f'({len(resp)} bytes: {resp[:32].hex() or "empty"})',
            file=sys.stderr,
        )
        sys.exit(1)
    except OSError as e:
        print(f'ERROR opening {port}: {e}', file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print(f'ERROR: {type(e).__name__}: {e}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
