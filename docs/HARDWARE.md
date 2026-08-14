# Hardware — Mira on UNO Q

See the diagram in the top-level `README.md`.

Summary of every physical connection in this build:

| Connection | Purpose |
|---|---|
| 5 V + GND pins | Powers the UNO Q. **The only two pins used. No GPIO.** |
| USB-C (board) -> hub | Data only. Board acts as USB host. |
| USB-C PD -> hub | Powers the hub and all peripherals. |
| Hub -> SO-101 | USB serial (CH340), servo bus at 1 Mbaud. |
| Hub -> camera | UVC webcam, wrist or overhead mount. |
| Hub -> speaker | Audio out. |
| Hub -> Boya mic | Wireless lavalier receiver, USB-C. |
| 12 V supply -> SO-101 | Servo power. **This is the emergency stop.** |
| Wi-Fi | Phone and laptop. LAN only, no internet required. |

## Not used

GPIO, ADC, DAC, PWM, I2C, SPI, CAN, and the analog header are all unused. The STM32
MCU is present but not in the control path for this build.
