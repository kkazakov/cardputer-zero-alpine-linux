# 01 — Hardware inventory & support matrix

Every peripheral of the CardputerZero, how Linux drives it, what *we* must
provide, and which stage delivers it. `TBD` items are resolved empirically in
[Stage 01](../stages/stage-01-hardware-discovery.md) — the stock image is the
authoritative source for chip identities and firmware.

| # | Subsystem | Hardware | Linux support | We must provide | Stage | Status |
|---|-----------|----------|---------------|-----------------|-------|--------|
| 1 | CPU | BCM2837, 4× Cortex-A53 @ 1 GHz (CM0 / RP3A0) | in-tree | nothing | S03 | planned |
| 2 | GPU | VideoCore IV | `vc4` (KMS); mesa Gallium `vc4` for GLES | CMA sizing, mesa pkg (desktop only) | S03/S08 | planned |
| 3 | RAM | 512 MB LPDDR2 | — | `gpu_mem` / `cma=` profiles (PLAN §6) | S03 | planned |
| 4 | Storage | microSD | bcm2835-sdhci, in-tree | good A1/A2-class card | S02 | planned |
| 5 | Boot firmware | VideoCore blobs (`bootcode.bin`, `start4.elf`, `fixup4.dat`) | closed — kept as-is | FAT32 boot partition | S03 | planned |
| 6 | Internal LCD | 1.9″ ST7789V3, SPI, **320×170** | `spi_bcm2835` + `drm_mipi_dbi` + `panel_mipi_dbi` + `vc4` | DT node (harvest) + panel init firmware `cardputerzero,st7789v_lcd.bin` in `/lib/firmware` | S03 | planned |
| 7 | LCD backlight | GPIO/PWM via DT | backlight sysfs | DT (harvest) | S03 | planned |
| 8 | Keyboard | 46-key matrix, TCA8418 I2C keypad controller | `tca8418_keypad` | DT (harvest) + console keymap `tca8418_keypad_m5stack_keymap.map` + optional xkb map for desktop | S04 | planned |
| 9 | USB host | DWC2 OTG (BCM2837) + on-board hub chip | `dwc2` (`dr_mode=host`), `usbhid`, `usb-storage` | DT host-mode (harvest); eudev automount rules | S05 | planned |
| 10 | USB-C ports | 2× USB-C + 1× USB-A (USB 2.0) | — | **TBD which C carries data** (S01) | S05 | TBD |
| 11 | Ethernet | 10/100, USB-attached — **TBD exact chip** (LAN9514-class `smsc95xx` most likely, Pi-family habit) | `smsc95xx` / `r8152` / `asix` / `cdc_ether` / `lan78xx` — all in-tree | identity from S01 `lsusb`; ifupdown-ng + udhcpc config | S05 | TBD |
| 12 | Wi-Fi | 2.4 GHz 802.11 b/g/n; CM0 is Zero-2W-class → expect brcmfmac43436 (43430 alt.) | `brcmfmac` | firmware `.bin` + board nvram `.txt` harvested from stock `/lib/firmware/brcm/` + `wpa_supplicant` | S05 | planned |
| 13 | Bluetooth | BT 4.2/BLE, HCI over UART | `hci_uart` + bluez | `.hcd` firmware (harvest); `hciattach`/`btuart`-equivalent OpenRC unit | S05 | planned |
| 14 | HDMI out | up to 1080p display; H.264 1080p30 codec | `vc4` HDMI connector (+ `vc4-hdmi` audio) | no `hdmi_force_hotplug` (runtime hotplug only); desktop session (docs/05) | S03/S08 | planned |
| 15 | Camera (standard model only) | Sony IMX219 8MP CSI | `bcm2835-unicam` + `imx219` + libcamera (rpi kernel) | on-demand CLI tools, never a boot service | S07 | planned |
| 16 | Audio codec | ES8389 (I2S), MEMS mic, 1 W speaker, 3.5 mm jack | ASoC codec + machine driver — **likely an M5 kernel patch**, mainline has only es8311/es8328 family | Phase A kernel first; Phase C `linux-cpz` port if needed (R1) | S07 | planned |
| 17 | HDMI audio | vc4-hdmi ASoC card | in-tree | routing config for desktop sessions | S07/S08 | planned |
| 18 | IMU | BMI270 accel+gyro | iio `bmi270` | DT node check (harvest) | S06 | planned |
| 19 | Magnetometer | BMM150 | iio — **TBD driver** (bmm150/bmc150_magn family) | identity + DT from S01; i2c-dev raw fallback | S06 | TBD |
| 20 | RTC | RX8130CE, I2C | `rtc-rx8130` (verify in stock lsmod) | hwclock OpenRC unit; battery keeps time across power-off | S06 | planned |
| 21 | Fuel gauge | BQ27220, I2C | `bq27xxx_battery` → `/sys/class/power_supply/bq27220-0/` | shell prompt/status helper | S06 | planned |
| 22 | Battery | 1500 mAh LiPo | via fuel gauge | power strategy (R9): blank, powersave, fast shutdown | S06/S09 | planned |
| 23 | Thermal | BCM2835 on-die + battery thermistor | `bcm2835_thermal`, power_supply temp | sysfs reads; no fans to control | S06 | planned |
| 24 | IR | IR TX/RX | **TBD topology** — rc-core (`gpio-ir-recv` / `gpio-ir-tx` / `pwm-ir-tx`) | DT node from S01; `ir-ctl` tests | S07 | TBD |
| 25 | Grove port | HY2.0-4P, I2C/UART switchable | `i2c-dev`, serial | expose `/dev/i2c-*`; switch mechanism from S01/docs | S07 | planned |
| 26 | Expansion bus | 2.54 mm 14-pin: SPI, UART, I2C, USB, GPIO, 5V | spidev/i2c-dev/serial/gpio | pinout table below; userspace access | S07 | planned |
| 27 | Power button / shutdown | **TBD wiring** | input event → triggerhappy | hotkey rules (poweroff/reboot) | S04/S06 | TBD |

## EXT 2.54-14P expansion bus — pinout

From M5Stack's official CardputerZero documentation (PinMap section), read
2026-11-18. The connector is a 2×7 (14-pin) 2.54 mm header on the top edge;
pins are numbered 1–14 in two columns (odd = left, even = right).

| Pin | Left function | Pin | Right function |
|-----|---------------|-----|----------------|
| 1 | HAT_P0 — `USB4_D_P` / GPIO26 (switchable) | 2 | **5VIN** |
| 3 | HAT_P1 — `USB4_D_N` / GPIO23 (switchable) | 4 | **GND** |
| 5 | GPIO22 | 6 | 5VOUT (switched, <500 mA) |
| 7 | SPI0_CLK — GPIO11 | 8 | GPIO2 — I2C1 SDA |
| 9 | SPI0_MOSI — GPIO10 | 10 | GPIO3 — I2C1 SCL |
| 11 | SPI0_MISO — GPIO9 | 12 | **GPIO15 — UART_RXD** |
| 13 | SPI0_CS1 — GPIO7 | 14 | **GPIO14 — UART_TXD** |

**Serial console for debugging = pins 4 (GND), 14 (device TX), 12 (device RX).**
This is the `serial0` console used by `cmdline.txt` (`console=serial0,115200`)
and by the `ttyS0` getty in `/etc/inittab`. Logic level is **3.3 V — never
connect a 5 V TTL adapter's TX to pin 12**.

The nearby **HY2.0-4P (Grove) port** carries the same UART by default
(`G4_I2C/UART_SW` low = UART):

| Grove wire | Signal |
|------------|--------|
| Black | GND |
| Red | 5V (enabled via M5IOE1 `PYG4_GROVE_EN`) |
| Yellow | GPIO14 — UART_TXD |
| White | GPIO15 — UART_RXD |

So a Grove-to-dupont cable is an easier console tap than the 14-pin header:
**Black → adapter GND, Yellow → adapter RX, White → adapter TX (optional)**.

## Status LEDs

M5IOE1 drives three keyboard indicator LEDs (`KEY_LED1/SHIFT`, `KEY_LED2/FN`,
`KEY_LED3/SYM`). Separately, the CM0 module has a status LED whose flash
pattern encodes boot failures (Raspberry Pi "LED warning flash codes"): a
repeating group of N flashes means e.g. 3 = generic boot failure, 4 =
`start*.elf` not found, 5 = `kernel.img` not found, 7 = kernel not a valid ARM
image, 8/9 = SDRAM init failure. Count the flashes in one repeating group
before assuming userspace is at fault.

## Open identification items (all resolved in Stage 01)

1. **Ethernet controller** — `lsusb` on stock OS (0424:9514 ⇒ LAN9514 →
   `smsc95xx`; 0bda:8152 ⇒ RTL8152 → `r8152`; 0b95:* ⇒ ASIX).
2. **Which USB-C carries OTG data** — plug a USB keyboard into each C port on
   the stock OS and watch `dmesg`. Record here.
3. **Wi-Fi/BT firmware files** — copy the whole `/lib/firmware/brcm/` from
   stock; the `.txt` nvram file is board-specific and *must* come from the
   stock image, not a generic download.
4. **ES8389 machine driver** — `lsmod | grep -i es8` + `/proc/asound/cards`
   on stock; if it's an out-of-tree M5 patch, find their kernel source (GPL —
   check their GitHub org; ask support if absent).
5. **IR topology** — DT nodes + stock app behavior.
6. **BMM150 driver identity** — `lsmod | grep -i bmm` on stock.
7. **Power button wiring** — `/proc/bus/input/devices` on stock + long-press
   behavior.
8. **Charging IC** — check for a charger node under
   `/sys/class/power_supply/` besides `bq27220-0`.

## Lite vs standard model

The **Lite** skips the IMX219 camera, the IMU suite, and the bundled microSD.
Everything else (CM0, keyboard, LCD, battery, Wi-Fi/BT, Ethernet, USB, IR) is
identical. Rows 15/18/19 are N/A on Lite; the OS image is the same either way
(drivers probe and stay silent when the hardware is absent).

## Handy sysfs paths (post-bring-up quick checks)

```sh
# battery / thermals
cat /sys/class/power_supply/bq27220-0/capacity      # %
cat /sys/class/power_supply/bq27220-0/temp          # deci-°C
cat /sys/class/thermal/thermal_zone0/temp          # SoC temp
# display
cat /sys/class/graphics/fb0/virtual_size           # 320,170 expected
cat /sys/class/graphics/fb0/blank                  # 0=on 1=off
# inputs
cat /proc/bus/input/devices                        # TCA8418 here
# drm connectors (HDMI hotplug state)
cat /sys/class/drm/card0-HDMI-A-1/status           # connected/disconnected
```

> Note: names like `bq27220-0` are as observed on the stock OS; exact sysfs
> node names are re-confirmed on our image during S06.
