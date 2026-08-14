/*
 * Mira — STM32 servo-power interlock.  Team JQK, Qualcomm Hack Challenge 2026.
 * Target: Arduino UNO Q, MCU side (FQBN arduino:zephyr:unoq)
 *
 * WHAT THIS IS
 *   The relay feeding the SO-101's 12 V servo rail is held closed ONLY while a
 *   fresh, checksum-valid heartbeat keeps arriving from the host. Heartbeat
 *   stops, E-stop opens, or a frame fails validation -> relay opens and the arm
 *   de-energises. Linux cannot override this; the MCU decides alone.
 *
 * WHY IT IS BUILT THIS WAY
 *   A safety interlock must fail toward "off" for every failure it can have:
 *   host crash, Wi-Fi drop, cable pull, Linux hang, cut E-stop wire, line noise
 *   on the UART, or a repeating stuck buffer. Each rule below exists because one
 *   of those can happen on a demo floor.
 *
 * SAFETY RULES (all must hold for the relay to be closed)
 *   1. state == ARMED, entered only by an explicit ARM command
 *   2. last valid heartbeat is younger than HEARTBEAT_TIMEOUT_MS
 *   3. E-stop reads healthy
 *   Anything else -> relay open. Faults LATCH: recovery needs a human.
 */

#include <Arduino.h>

/* WATCHDOG: NOT PRESENT ON THIS BUILD. Read this before trusting the interlock.
 *
 * A watchdog would cover one failure the rest of this code cannot: the firmware
 * hanging while the relay is closed. Reset opens the relay, so a watchdog reset
 * is a safe outcome.
 *
 * TRIED AND REVERTED, 2026-08-11: pulling in <zephyr/device.h> and
 * <zephyr/devicetree.h> to use Zephyr's wdt_* API breaks the link --
 * "undefined reference to __device_dts_ord_175" from Arduino_RouterBridge's
 * monitor.h, which backs Serial. The sketch is an llext loaded into a Zephyr
 * image Arduino prebuilt, and adding devicetree headers disturbs the ordinals
 * that image already fixed. A broken build is worse than a known gap, so the
 * watchdog stays out until Arduino ships watchdog support in this core.
 *
 * CONSEQUENCE: a firmware hang holding the relay closed is NOT covered by
 * software. Fit the hardware failsafe in docs/INTERLOCK.md section 8 if you
 * need that guarantee. Everything else -- host loss, network loss, E-stop,
 * bad frames -- is covered and is what the demo actually exercises. */
#define MIRA_HAS_WDT 0

// ---------------------------------------------------------------- pin mapping
static const uint8_t PIN_RELAY   = 7;   // servo-rail relay driver
static const uint8_t PIN_ESTOP   = 2;   // E-stop, NORMALLY CLOSED to GND
static const uint8_t PIN_LED_ARM = 5;   // green: rail live
static const uint8_t PIN_LED_SAFE= 6;   // red:   rail dead / fault
static const uint8_t PIN_ISD1820 = 8;   // audio module, edge-triggered play

/* RELAY MODULE POLARITY -- READ THIS.
 * true  = module energises the relay on a HIGH pin (safe: reset leaves pins low)
 * false = ACTIVE-LOW module. DANGEROUS without an external pull-up: during reset
 *         the pin floats/low and the relay would CLOSE, energising the arm while
 *         the MCU is not in control. If you must use an active-low module, fit a
 *         10k pull-up from the drive pin to 3V3 and verify with a meter that the
 *         relay is OPEN while the MCU is held in reset. */
static const bool RELAY_ACTIVE_HIGH = true;

/* E-stop wiring: normally-closed contacts between PIN_ESTOP and GND, pin pulled
 * up internally. Healthy = LOW. Pressed = HIGH. A CUT WIRE ALSO READS HIGH, so a
 * broken E-stop line fails safe instead of silently disabling protection. */
static const bool ESTOP_HEALTHY_LEVEL = LOW;

// ------------------------------------------------------------------- timing
static const uint32_t HEARTBEAT_TIMEOUT_MS = 250;  // host sends at 20 Hz (50 ms)
static const uint32_t STATUS_PERIOD_MS     = 200;  // status back to host at 5 Hz
static const uint32_t ESTOP_CLEAR_STABLE_MS= 50;   // debounce only when CLEARING
static const uint32_t ISD1820_PULSE_MS     = 150;  // play trigger width
static const size_t   RX_BUFFER_MAX        = 96;

// -------------------------------------------------------------------- state
enum InterlockState : uint8_t { STATE_SAFE = 0, STATE_ARMED = 1, STATE_FAULT = 2 };

enum FaultFlag : uint8_t {
  FAULT_NONE            = 0,
  FAULT_HEARTBEAT_LOST  = 1 << 0,
  FAULT_ESTOP           = 1 << 1,
  FAULT_BAD_FRAMES      = 1 << 2,
  FAULT_ARM_REFUSED     = 1 << 3,
};

static InterlockState state       = STATE_SAFE;
static uint8_t        faultFlags  = FAULT_NONE;

static uint32_t lastHeartbeatMs   = 0;
static bool     everHeartbeat     = false;
static uint32_t lastSeq           = 0xFFFFFFFFul;  // sentinel: nothing accepted
static uint32_t statusSeq         = 0;

static uint32_t lastStatusMs      = 0;
static uint32_t badFrameCount     = 0;
static uint32_t estopHealthySince = 0;

static uint32_t isdPulseStartMs   = 0;
static bool     isdPulseActive    = false;

static char   rxBuffer[RX_BUFFER_MAX];
static size_t rxLength = 0;

static bool wdtActive = false;           // true only if the watchdog really armed

// ---------------------------------------------------------------- primitives

/* CRC-8/ATM: polynomial 0x07, init 0x00, MSB-first. Mirrored byte-for-byte in
 * bridge/mira_bridge.py so both ends reject the same corrupt frames. Its job is
 * to stop UART noise from ever looking like a valid heartbeat. */
static uint8_t crc8(const char *data, size_t length) {
  uint8_t crc = 0x00;
  for (size_t i = 0; i < length; i++) {
    crc ^= (uint8_t)data[i];
    for (uint8_t bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
    }
  }
  return crc;
}

static bool estopIsHealthy() {
  return digitalRead(PIN_ESTOP) == ESTOP_HEALTHY_LEVEL;
}

static bool heartbeatIsFresh() {
  return everHeartbeat && (millis() - lastHeartbeatMs) < HEARTBEAT_TIMEOUT_MS;
}

/* The ONLY place the relay pin is ever written. Every safety condition is
 * re-evaluated here, so no other code path can leave the rail live by mistake. */
static void driveOutputs() {
  const bool shouldBeClosed = (state == STATE_ARMED)
                           && heartbeatIsFresh()
                           && estopIsHealthy();

  digitalWrite(PIN_RELAY, shouldBeClosed == RELAY_ACTIVE_HIGH ? HIGH : LOW);
  digitalWrite(PIN_LED_ARM,  shouldBeClosed ? HIGH : LOW);
  digitalWrite(PIN_LED_SAFE, shouldBeClosed ? LOW  : HIGH);
}

static void announce() {                 // fire the ISD1820 once, non-blocking
  digitalWrite(PIN_ISD1820, HIGH);
  isdPulseStartMs = millis();
  isdPulseActive  = true;
}

static void serviceAnnounce() {
  if (isdPulseActive && (millis() - isdPulseStartMs) >= ISD1820_PULSE_MS) {
    digitalWrite(PIN_ISD1820, LOW);
    isdPulseActive = false;
  }
}

/* Latch a fault: drop the rail and refuse to re-arm until a human sends RST.
 * Latching is deliberate -- a flapping network must not silently re-energise a
 * robot arm the moment it recovers. */
static void raiseFault(uint8_t flag) {
  const bool wasLive = (state == STATE_ARMED);
  faultFlags |= flag;
  state = STATE_FAULT;
  driveOutputs();
  if (wasLive) announce();               // audible only on a real drop
}

// ------------------------------------------------------------ host protocol

static void sendStatus() {
  const uint32_t age = everHeartbeat ? (millis() - lastHeartbeatMs) : 0xFFFFFFFFul;
  char payload[80];
  const int n = snprintf(payload, sizeof(payload),
                         "M,ST,%u,%lu,%lu,%u,%u,%u",
                         (unsigned)state,
                         (unsigned long)statusSeq++,
                         (unsigned long)(age > 99999ul ? 99999ul : age),
                         (unsigned)(estopIsHealthy() ? 1 : 0),
                         (unsigned)((state == STATE_ARMED && heartbeatIsFresh()
                                     && estopIsHealthy()) ? 1 : 0),
                         (unsigned)faultFlags);
  if (n <= 0 || (size_t)n >= sizeof(payload)) return;
  Serial.print(payload);
  Serial.print(',');
  if (crc8(payload, (size_t)n) < 0x10) Serial.print('0');
  Serial.println(crc8(payload, (size_t)n), HEX);
}

/* Validate one line and act on it. Rejects anything whose CRC does not match,
 * and rejects a heartbeat whose sequence number has not advanced -- that second
 * check is what stops a stuck/repeating UART buffer from holding the rail live. */
static void handleLine(char *line) {
  char *lastComma = strrchr(line, ',');
  if (!lastComma || lastComma == line) { badFrameCount++; return; }

  const size_t payloadLength = (size_t)(lastComma - line);
  const uint8_t expected = (uint8_t)strtoul(lastComma + 1, nullptr, 16);
  if (crc8(line, payloadLength) != expected) { badFrameCount++; return; }
  *lastComma = '\0';                     // payload is now a bare C string

  if (strncmp(line, "M,", 2) != 0) { badFrameCount++; return; }
  char *verb = line + 2;
  char *comma = strchr(verb, ',');
  if (!comma) { badFrameCount++; return; }
  *comma = '\0';
  const uint32_t seq = strtoul(comma + 1, nullptr, 10);

  if (strcmp(verb, "HB") == 0) {
    if (seq == lastSeq) { badFrameCount++; return; }   // replay / stuck buffer
    lastSeq = seq;
    lastHeartbeatMs = millis();
    everHeartbeat = true;
    return;
  }

  if (strcmp(verb, "ARM") == 0) {
    // Refuse to arm unless the world is already safe AND the host is live.
    if (state == STATE_FAULT || !estopIsHealthy() || !heartbeatIsFresh()) {
      faultFlags |= FAULT_ARM_REFUSED;
      return;
    }
    state = STATE_ARMED;
    return;
  }

  if (strcmp(verb, "DIS") == 0) { state = STATE_SAFE; return; }

  if (strcmp(verb, "RST") == 0) {
    if (!estopIsHealthy()) return;       // never clear a fault while pressed
    faultFlags = FAULT_NONE;
    badFrameCount = 0;
    state = STATE_SAFE;
    return;
  }

  badFrameCount++;
}

static void readHostSerial() {
  while (Serial.available() > 0) {
    const char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (rxLength > 0) {
        rxBuffer[rxLength] = '\0';
        handleLine(rxBuffer);
        rxLength = 0;
      }
      continue;
    }
    if (rxLength < RX_BUFFER_MAX - 1) {
      rxBuffer[rxLength++] = c;
    } else {
      rxLength = 0;                      // oversized line: drop it, count it
      badFrameCount++;
    }
  }
}

// ------------------------------------------------------------------- arduino

void setup() {
  /* Outputs first, and OFF, before anything else can run. */
  pinMode(PIN_RELAY, OUTPUT);
  digitalWrite(PIN_RELAY, RELAY_ACTIVE_HIGH ? LOW : HIGH);   // rail dead
  pinMode(PIN_LED_ARM,  OUTPUT); digitalWrite(PIN_LED_ARM,  LOW);
  pinMode(PIN_LED_SAFE, OUTPUT); digitalWrite(PIN_LED_SAFE, HIGH);
  pinMode(PIN_ISD1820,  OUTPUT); digitalWrite(PIN_ISD1820,  LOW);

  pinMode(PIN_ESTOP, INPUT_PULLUP);

  Serial.begin(115200);

  /* Say plainly whether the hang protection is real on this build. Anyone
   * reading the serial log can then trust or distrust the safety claim. */
  Serial.println(wdtActive ? "M,BOOT,watchdog=ACTIVE"
                           : "M,BOOT,watchdog=ABSENT-fit-hardware-failsafe");

  state = STATE_SAFE;
  driveOutputs();
}

void loop() {
  readHostSerial();

  /* E-stop: assert instantly, clear only after it has been stable. Fast to trip,
   * slow to trust -- the asymmetry is intentional. */
  if (!estopIsHealthy()) {
    estopHealthySince = 0;
    if (state != STATE_FAULT || !(faultFlags & FAULT_ESTOP)) raiseFault(FAULT_ESTOP);
  } else if (estopHealthySince == 0) {
    estopHealthySince = millis();
  }

  /* Losing the host while live is a fault, not a quiet disarm. */
  if (state == STATE_ARMED && !heartbeatIsFresh()) {
    raiseFault(FAULT_HEARTBEAT_LOST);
  }

  /* Sustained garbage on the link means we no longer trust it. */
  if (state == STATE_ARMED && badFrameCount > 20) {
    raiseFault(FAULT_BAD_FRAMES);
  }

  driveOutputs();
  serviceAnnounce();

  if (millis() - lastStatusMs >= STATUS_PERIOD_MS) {
    lastStatusMs = millis();
    sendStatus();
  }
}
