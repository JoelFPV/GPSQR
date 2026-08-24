-- ============================================================================
--  GPSQR 1.2.1 - full-screen GPS / ELRS telemetry widget for EdgeTX color radios
--
--  Shows satellites, live coordinates, a scannable Google-Maps QR code, height
--  above take-off (plus MSL), speed, course, distance to home, trip, flight
--  time, the radio battery, milliamp-hours drawn, the time of day, the flight
--  controller's own flight-mode string, and an ELRS RF panel. Works with
--  Betaflight, INAV and ArduPilot over CRSF, with the firmware detected from
--  that same mode string -- see AP_MODES for the one ArduPilot setting worth
--  changing (RC_OPTIONS bit 12, CRSF_FM_DISARM_STAR).
--
--  SCREENS: exactly three panels are accepted, each with its own entry in
--  PROFILES. 800x480 (RadioMaster TX16S MK3, the only EdgeTX board with that
--  panel) and 480x272 (TX16S MK1/MK2, X10, X12S, T16, T18, ...) are both
--  measured and flight-tested; 480x320 (GX15, PL18, ST16, T15, T22, TX15) was
--  measured on a TX15 and is untested on the other five. Any other panel is
--  REFUSED with an on-screen notice rather than approximated -- handing a
--  320x240 radio a layout measured for a bigger one just draws a third of it
--  off the edge.
--  A supported panel whose ZONE is too small to lay out legibly gets the setup
--  checklist instead of a squashed instrument -- see the L.ok check in
--  computeLayout.
--
--  FIRMWARE: EdgeTX 2.8.0 and newer. Every API used here exists in 2.8; the one
--  exception was STDSIZE, which Lua only gained in 2.11, so it is resolved at
--  load time (see F_STD).
--
--  A project by Joel Conus, who designed it, specified every behavior here,
--  flew each iteration and measured the hardware these numbers are calibrated
--  to. The code was written by Claude (Anthropic).
--  Copyright (c) 2026 Joel Conus. MIT license - see LICENSE.
--  (The name is really "Joel" with a diaeresis on the e, as LICENSE has it.
--   Spelled ASCII here on purpose: this file is 100% ASCII so that no editor,
--   SD-card copy or Lua compile step can mangle a byte of it. Please keep it so.)
--
--  ---------------------------------------------------------------------------
--  DESIGN RULES. Each of these was paid for with a field test; please read
--  before "simplifying" anything.
--
--  1. NEVER DISPLAY WHAT CANNOT BE KNOWN.
--     White = live. Gray = the last known value, link down. "--" = never known.
--     A confidently wrong number is worse than an absent one.
--
--  2. EVERYTHING KEYS OFF ARMING, read from the flight controller's own
--     telemetry (see readArmed):
--        arm    -> home captured here; trip and flight timer zeroed
--        land   -> trip and timer FREEZE; the distance/altitude/speed cards
--                  switch to that flight's MAXIMA ("MAX ..." labels)
--        re-arm -> re-homes at the new spot, fresh flight
--
--  3. TELEMETRY LOSS FREEZES, IT DOES NOT ERASE. EdgeTX hands Lua a 0 for every
--     telemetry sensor once the link drops (not the last value), so anything
--     model-sourced must be held explicitly - see readSensors.
--
--  4. THE CPU BUDGET IS REAL. refresh() gets ~20,000 VM instructions; overrun
--     disables the widget permanently. The QR is therefore built by a resumable
--     state machine, a slice per frame. Read the note above QR_SLICE first.
--
--  5. NO CONTROLS. Nothing on this screen is tappable and no key does anything.
--     Partly a choice -- an instrument should not need operating -- and partly
--     the platform: EdgeTX only delivers input to a widget in FULL-SCREEN mode,
--     so any control would be invisible to anyone running it as a plain screen.
--     Every setting is a constant in CFG below.
--
--  6. TRUST THE GPS, NOT THE SENSOR, FOR ANYTHING DERIVABLE. Course over ground
--     is computed from consecutive fixes rather than read from Hdg, because the
--     sensor arrives signed on some setups and a factor of ten out on others.
--     Distance and trip already worked this way. See compassDeg and bearingDeg.
--
--  Install: copy the GPSQR FOLDER to SD:/WIDGETS/GPSQR/main.lua. No reboot
--           needed -- widgets are picked up dynamically.
--           (Color radios have no SCRIPTS/TELEMETRY - this is a widget.)
--  Enable : Screens -> one-zone layout -> GPSQR, with the top bar, flight mode,
--           sliders and trims all OFF so it gets the whole screen.
-- ============================================================================

-- Which build this file is, for bug reports. A widget is copied to an SD card and
-- lives there for months, so a copy has to be identifiable on its own -- "grep
-- VERSION main.lua" -- without the repository it came from.
--
-- NOTHING READS THIS, on purpose. It is not drawn: the screen is an instrument
-- and a version number is not flight information, so it would only take room from
-- something that is. It is a local rather than a comment so it survives a tool
-- that strips comments, and it is recorded here so the next dead-code audit
-- leaves it alone.
local VERSION = "1.2.1"

-- ---------------------------------------------------------------------------
--  USER CONFIGURATION
-- ---------------------------------------------------------------------------
local CFG = {
  -- THE setting most people change. Set it once here; there is no on-screen
  -- toggle, because a preference you pick once does not deserve a permanent
  -- button on a flight instrument.
  UNITS         = "metric",   -- "metric" (m, km, km/h) or "imperial" (ft, mi, mph)
  SPEED_TO_KMH  = 1.0,        -- multiply raw GSpd to get km/h  (knots: 1.852, m/s: 3.6)
  ALT_TO_M      = 1.0,        -- multiply raw altitude to get meters (feet sensor: 0.3048)

  -- GEOID CORRECTION, in meters, added to the MSL readout only.
  --
  -- A GPS computes height above the WGS84 ELLIPSOID, a smooth mathematical figure.
  -- Mean sea level follows the GEOID, which is lumpy, and the two differ by -105 m
  -- to +85 m depending where you are. Unless the flight controller applies a geoid
  -- model, the altitude it sends is ellipsoidal and reads high or low by that
  -- separation -- measured near Lausanne 2026-07-28: a 670 m field reported 711 to
  -- 723 m, the ~+49 m local undulation plus normal GPS vertical wander.
  --
  -- To calibrate: stand at a spot whose elevation you know (a map, a trig point,
  -- your own field), read the MSL line, and set this to  true - shown.  It is a
  -- whole-of-region constant, so one value covers everywhere you normally fly.
  -- Leave at 0 to display exactly what the flight controller sends.
  --
  -- Affects the MSL line and nothing else: height above take-off, distance, trip
  -- and the QR position are all differences or coordinates, and never see it.
  MSL_OFFSET    = 0,

  MIN_SATS      = 6,          -- satellites required for a valid fix / home lock
  -- Home is captured at TAKE-OFF (see the arm edge), so no stationary-detection
  -- settings are needed. This one only feeds the motion arm/disarm fallback.
  STILL_SPD     = 3,          -- km/h under which the model counts as "not moving"

  -- ARMED / DISARMED comes from the model itself whenever possible.
  -- "auto" picks the best source available, in this order:
  --   1. the flight controller's flight-mode telemetry (ARM_SENSORS, see below)
  --   2. a radio switch, if you name one here instead of "auto" (e.g. "sf")
  --   3. failing both, motion (takes off / lands) -- a guess, not a real signal
  ARM_MODE      = "auto",
  ARM_SPEED     = 8,          -- km/h  -> motion-fallback take-off detection
  LAND_STILL_T  = 5,          -- seconds stationary before the motion fallback disarms

  -- Meters the FC's altitude may change between two telemetry frames before the
  -- widget calls it a REFERENCE change rather than motion (see updateLogic).
  -- Telemetry arrives several times a second, so even a 30 m/s climb moves only
  -- a few meters per frame; 100 m would need ~1000 m/s. Erring HIGH on purpose:
  -- mistaking a real climb for a reference change would silently under-read
  -- altitude for the rest of the flight, which is worse than missing a switch.
  ALT_JUMP_M    = 100,

  -- Meters; movement smaller than this is GPS jitter, not travel. Measured on a
  -- TX16S/ELRS setup sitting still: excursions reach ~2 m, so 3 m clears them.
  -- Measured from the last ACCEPTED point, not the previous frame, so genuine
  -- slow movement still accumulates once it passes the threshold.
  TRIP_MIN_STEP = 3.0,
  TRIP_MAX_STEP = 400,        -- meters; ignore single jumps larger than this (GPS glitch)

  QR_URL        = "https://maps.google.com/?q=",
  -- Decimals in the QR URL and the on-screen LAT/LON. SIX, because six is all
  -- the radio actually knows: CRSF carries lat/lon as int32 in 1e-7 deg, but
  -- EdgeTX divides by 10 on the way in (telemetry/crossfire.cpp:
  -- `processCrossfireTelemetryValue(GPS_LATITUDE_INDEX, value/10)`) and then
  -- hands Lua `gps.latitude * 0.000001` as a 32-bit float. So the real grid is
  -- 1e-6 deg (~11 cm) and a 7th decimal is only float32 rounding noise -- it
  -- looks like position but carries none, so it is not shown.
  QR_PREC       = 6,          -- worst-case URL is 49 bytes; the Version-3 QR holds 53
  DISP_PREC     = 6,          -- keep equal to QR_PREC so the readout matches the code

  -- METERS THE MODEL MUST MOVE before the QR is re-encoded.
  --
  -- The code is always on screen, and it rebuilds when the POSITION CHANGES --
  -- not on a clock. There used to be a QR_REFRESH timer (5 s); it was the single
  -- largest contributor to how stale the displayed code could be. The lag from
  -- "the model was here" to "the code says so" is three terms:
  --     time since the fix was sampled   -- set by your telemetry ratio
  --   + time waiting for the next rebuild -- was up to QR_REFRESH, now ~0
  --   + the build itself                  -- 22 frames = 3.2 s on an MK3,
  --                                          3.9 s on an MK2 (see QR_SLICE)
  -- Removing the middle term took the worst case at a 1 Hz fix rate from ~10.6 s
  -- to ~4.2 s (MK3) / ~4.9 s (MK2), and cost nothing: a rebuild cannot start
  -- while one is running (qrBusy), so the build is its own rate limiter.
  --
  -- THOSE SECONDS ARE FRAMES x THE RADIO'S REFRESH PERIOD, not CPU time, and the
  -- period was measured rather than assumed -- an earlier version of this note
  -- said 0.93 s because it multiplied the frame count by LVGL's 30 ms display
  -- refresh, which is not the rate EdgeTX calls a widget at. The field bears the
  -- corrected model out: at QR_SLICE 20 the build took 32 frames, and the two
  -- radios were timed at 4.5 s and 5.5 s per code -- 32 x 145 ms and 32 x 177 ms.
  --
  -- WHY A DISTANCE AND NOT "ANY NEW FIX": at 6 decimals the coordinate string
  -- changes on essentially every frame, because a parked receiver wanders. This
  -- is the same jitter floor TRIP_MIN_STEP uses and it was measured the same
  -- way -- a stationary TX16S/ELRS setup reaches ~2 m of excursion, so 3 m
  -- clears it. It is a SEPARATE constant on purpose: the two answer different
  -- questions (do not accumulate phantom trip / do not burn CPU re-encoding a
  -- model that has not moved), and binding them would mean retuning one
  -- silently changed the other.
  --
  -- Measured from the position the CURRENT CODE ENCODES, not from the previous
  -- frame, so a slow drift still accumulates and eventually triggers -- exactly
  -- as TRIP_MIN_STEP does. In flight the gate never blocks: at 42 km/h the model
  -- covers 3 m in a quarter of a second.
  QR_MIN_MOVE   = 3.0,

  -- radio-battery gauge. The real min/max are read from your radio's battery
  -- range (Radio Settings) automatically; these are only a fallback.
  BATT_MIN      = 6.6,        -- volts = 0%
  BATT_MAX      = 8.4,        -- volts = 100%

  -- sensor name fall-backs (first that exists is used)
  -- `Tmp2` used to be listed here as a fallback, because that is the FrSky
  -- convention for a satellite count. On a CRSF/ELRS link -- which is what this
  -- widget targets -- `Tmp2` is a TEMPERATURE, so a model carrying one while
  -- `Sats` had not been discovered would have its ESC temperature drawn as a
  -- satellite count. That cuts both ways: a warm ESC invents a confident count,
  -- and a cold one (2 degrees in winter) reads as "below MIN_SATS" and suppresses
  -- a perfectly good position. Rule 1 says an honest "--" beats a plausible
  -- wrong number, so the fallback is gone. FrSky users: add it back here.
  SAT_SENSORS   = { "Sats" },
  -- Altitude is shown two ways. The BIG number is height above the launch point
  -- (what you actually fly by); the small figure on the label row is absolute MSL.
  --   ALT_MSL_SENSORS -- GPS altitude above sea level.
  --   ALT_REL_SENSORS -- the FC's own height above the arming point. Betaflight
  --                      zeroes this estimate when you arm, so it is already
  --                      relative. If the sensor is absent, height above home is
  --                      computed as MSL minus the MSL recorded at the home point.
  --
  -- MOST MODELS HAVE ONLY ONE OF THESE, and which name it wears is decided by
  -- your EdgeTX version rather than by the aircraft: a model with no barometric
  -- telemetry sends a single CRSF altitude, discovered as "GAlt" on 2.12+ and as
  -- "Alt" on 2.8-2.11. All three configurations work and read the same; only the
  -- route through the code differs. Do NOT "fix" a missing sensor by adding the
  -- other name to both lists -- on a radio that really has both, that would feed
  -- the same measurement in twice under two meanings.
  --
  -- ARDUPILOT needs no configuration and no code path of its own: it sends ONE
  -- altitude, the GPS's own location.alt, over the standard CRSF GPS frame
  -- (AP_CRSF_Telem.cpp calc_gps()). That is genuine above-sea-level altitude and
  -- it is never re-datumed at arm -- the same shape as Betaflight master/5.x -- so
  -- it is discovered as GAlt or Alt exactly like any other single-altitude model
  -- and handled by the same machinery.
  --
  -- ON INAV THERE IS NO MSL AT ALL, whatever the sensor is called. INAV puts its
  -- position estimator's height above the launch origin into the CRSF altitude
  -- field, so the reading is relative at every moment and the MSL line is
  -- suppressed on an INAV model. This is detected from the flight-mode string
  -- (see identifyFC) and needs no configuration.
  --
  -- If your FC's "Alt" misbehaves (some report absolute altitude, or change
  -- their reference mid-flight), set ALT_REL_SENSORS = {} to ignore it and let
  -- the widget derive height above take-off from GPS altitude instead. If both
  -- sensors exist and disagree, whichever you trust goes in ALT_MSL_SENSORS.
  ALT_MSL_SENSORS = { "GAlt" },
  ALT_REL_SENSORS = { "Alt" },
  SPD_SENSORS   = { "GSpd" },
  HDG_SENSORS   = { "Hdg", "Cog", "GPS course" },
  -- Milliamp-hours drawn from the flight pack. Needs a current sensor on the FC;
  -- without one the cell reads "--" like any other missing sensor. This is the
  -- endurance number that elapsed time cannot give you, because it accounts for
  -- how hard you have been flying.
  MAH_SENSORS   = { "Capa" },
  -- Flight-controller flight-mode string. Betaflight/INAV send this over CRSF
  -- and encode the arming state in it (see readArmed): this is the real
  -- ARMED/DISARMED signal from the model. Run "Discover new sensors" to get it.
  --
  -- ARDUPILOT sends the very same frame (AP_CRSF_Telem.cpp calc_flight_mode(),
  -- the same "FM" sensor) but does NOT encode arm state in it by default -- the
  -- string is the bare mode name ("STAB", "LOIT", "AUTO", ...) armed or not.
  -- ArduPilot has its own opt-in for the Betaflight-style marker: RC_OPTIONS
  -- bit 12, "Annotate flight mode with * on disarm" (CRSF_FM_DISARM_STAR; Mission
  -- Planner shows it by name in the RC_OPTIONS bitmask). Turn it on and this
  -- widget reads the trailing "*" exactly as it does on Betaflight.
  --
  -- WITHOUT it, arm state falls back to a radio switch (ARM_MODE below) or to
  -- motion -- deliberately, rather than guessing. An unmarked ArduPilot mode name
  -- means either "armed" or "disarmed, option off", and those are not
  -- distinguishable; home, the trip and the timer all key off the arm edge, so
  -- inventing one is worse than admitting there is no source. See readArmed.
  ARM_SENSORS   = { "FM", "Fmod", "Flight mode" },
}

-- Data mask. Hard-wired to 2 (condition x % 3 == 0): the masking loop is
-- specialised for it, so this is a documentation constant, not a knob.
local QR_MASK = 2

-- Seconds after arming during which a GPS altitude that collapses below the
-- launch elevation can only be the flight controller re-datuming it -- the model
-- is still on the ground and cannot have descended. See updateLogic.
local ALT_ZERO_T = 15

-- Seconds a large step in the DISARMED GPS altitude must persist before it is
-- accepted as the new launch elevation. Long enough that a re-datum arriving just
-- ahead of the arm string is never believed (the arm follows within a frame or
-- two), short enough that genuinely moving to another field costs one pause.
local MSL_SETTLE = 5

-- ---------------------------------------------------------------------------
--  small math helpers
-- ---------------------------------------------------------------------------
local floor = math.floor
local function abs(a) if a < 0 then return -a else return a end end
local function max(a, b) if a > b then return a else return b end end
local function min(a, b) if a < b then return a else return b end end
local PI    = math.pi
local D2R   = PI / 180
local EARTH = 6371000

local POW2 = {}
for i = 0, 24 do POW2[i] = 2 ^ i end

local function atan2(y, x)
  if x > 0 then return math.atan(y / x)
  elseif x < 0 then
    if y >= 0 then return math.atan(y / x) + PI else return math.atan(y / x) - PI end
  else
    if y > 0 then return PI / 2 elseif y < 0 then return -PI / 2 else return 0 end
  end
end

local function distanceM(la1, lo1, la2, lo2)
  local dLat = (la2 - la1) * D2R
  local dLon = (lo2 - lo1) * D2R
  local s1 = math.sin(dLat / 2)
  local s2 = math.sin(dLon / 2)
  local a = s1 * s1 + math.cos(la1 * D2R) * math.cos(la2 * D2R) * s2 * s2
  if a < 0 then a = 0 elseif a > 1 then a = 1 end
  return EARTH * 2 * atan2(math.sqrt(a), math.sqrt(1 - a))
end

-- "Has it moved at least `m` meters?" -- a THRESHOLD test, not a measurement.
--
-- Deliberately not distanceM. That one is a haversine: two sines, two cosines, a
-- square root and an atan2, which is the right tool for the distance and trip
-- READOUTS because those numbers are shown to the pilot. This one is asked once
-- per frame by the QR trigger, where the answer is a yes/no about a few meters --
-- and paying haversine for it measured 4 ticks on EVERY frame, build or not.
--
-- Equirectangular instead: scale the longitude difference by cos(latitude) and
-- treat the little patch as flat. Over the distances this gate cares about the
-- error is parts per million -- orders of magnitude below the GPS noise the
-- threshold exists to reject -- and it degrades only near the poles, where it
-- under-reports and so merely delays a rebuild.
--
-- Compared SQUARED, so there is no square root either: one cosine and a handful
-- of multiplies. Both sides are in radians of arc, hence the m / EARTH.
local function movedAtLeast(la1, lo1, la2, lo2, m)
  local dLat = (la2 - la1) * D2R
  local dLon = (lo2 - lo1) * D2R * math.cos(la1 * D2R)
  local lim  = m / EARTH
  return (dLat * dLat + dLon * dLon) >= (lim * lim)
end

-- Initial great-circle bearing from point 1 to point 2, as a compass bearing.
-- Used to work out COURSE OVER GROUND from two consecutive fixes, because the
-- heading SENSOR cannot be trusted to arrive in any particular unit or sign --
-- see the note on compassDeg and HDG_SENSORS.
local function bearingDeg(la1, lo1, la2, lo2)
  local p1, p2 = la1 * D2R, la2 * D2R
  local dl = (lo2 - lo1) * D2R
  local y = math.sin(dl) * math.cos(p2)
  local x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
  return atan2(y, x) / D2R          -- -180..180; compassDeg() makes it a bearing
end

-- ===========================================================================
--  QR ENCODER  -  Version 3, ECC level L, byte mode, single block, fixed mask
--  Capacity 53 bytes.  Returns matrix m[y][x] (boolean, true = dark) and size.
-- ===========================================================================
-- XOR is the hot operation in Reed-Solomon, and EdgeTX's per-call instruction
-- budget is tiny, so do it a NIBBLE at a time from a 16x16 table instead of
-- bit-by-bit (~3x fewer VM instructions, and bxor8 below is branch-free).
-- Filled by the PH_XOR build phase on first use -- NOT at load time, because
-- loading the widget file runs under the same instruction limit as refresh().
local XOR4 = {}

-- general (any width) -- used for the GF table build where values exceed 8 bits
local function bxor(a, b)
  local r, p = 0, 1
  while a > 0 or b > 0 do
    r = r + XOR4[a % 16][b % 16] * p
    a = floor(a / 16); b = floor(b / 16); p = p * 16
  end
  return r
end

-- byte-only fast path (both args guaranteed 0..255)
local function bxor8(a, b)
  return XOR4[floor(a / 16)][floor(b / 16)] * 16 + XOR4[a % 16][b % 16]
end

-- ---------------------------------------------------------------------------
--  Work slicing.
--  EdgeTX gives a widget's refresh() only ~20,000 Lua VM instructions
--  (radio/src/lua/lua_widget.cpp: MAX_INSTRUCTIONS = 20000/100, the debug hook
--  fires every 200 instructions and errors once the counter passes 100 ->
--  "ERROR in refresh(): CPU limit", which kills the widget permanently).
--  A whole QR build is ~10x that, so it MUST be spread over several frames.
--
--  Coroutines would be the obvious tool, but EdgeTX does NOT give scripts the
--  coroutine library: its luaL_openlibs (thirdparty/Lua/src/linit.c) registers
--  only _G, io, dir, bitmap, lvgl, package and string. lcorolib.c is present in
--  the source tree but never registered, so `coroutine` is nil and touching it
--  raises "attempt to index a nil value (field 'coroutine')" on the radio.
--
--  The build is therefore an explicit resumable STATE MACHINE: qrStep() does at
--  most QR_SLICE units of work per frame and remembers where it stopped (see
--  the PH_* phases and the job table J further down).
-- ---------------------------------------------------------------------------
-- Work per frame, in the same "ticks" the watchdog counts (1 tick = 200 VM
-- instructions, budget = 100). A slice may overshoot by one unit (see the
-- "first" rule in qrStep), so the worst frame is roughly draw + QR_SLICE + the
-- dearest phase.
--
-- 30 IS A WALL-CLOCK SETTING, NOT A CPU ONE, and that is worth understanding
-- before changing it. EdgeTX does not call refresh() at the display rate: it was
-- measured on the radios at ~11-13 Hz idle, so a frame is ~145 ms on an MK3 and
-- ~177 ms on an MK2 (Snapshots/FPSTEST-*, and Tests/qr_options_probe.py). That
-- period is paid ONCE PER FRAME whatever the frame contains -- so the build costs
-- FRAMES, not ticks, and a bigger slice buys real seconds by needing fewer of
-- them. At 20 the rebuild took 32 frames (4.6 s on an MK3, 5.7 s on an MK2, both
-- confirmed against the radios); at 30, with the function patterns cached, it
-- takes 22 -- 3.2 s and 3.9 s -- for six points of peak. Worst frame measured
-- in continuous flight, every sensor present and a code on screen: 67 of 100
-- (69 on some fix/build alignments). Parked, with a code up and no build
-- running, it is 36. See Tests/profile_frames.py, which sweeps the alignment.
--
-- The MK2 is CPU-bound (its refresh rate falls 42% between an idle frame and a
-- 60%-loaded one) while the MK3 holds a flat period, so the same slice buys less
-- on the MK2. Both still gain.
--
-- Bigger = finishes in fewer frames, smaller = more headroom. See PH_COST below.
local QR_SLICE = 30

local function getbit(x, i) return floor(x / POW2[i]) % 2 end

-- Galois-field log/antilog tables, also built lazily (see XOR4 above). Building
-- these two tables at load time cost ~136% of the load budget on its own.
local EXP, LOG = {}, {}
local tablesReady = false

-- one row of the nibble-XOR table (16 rows total, built by the PH_XOR phase)
local function buildXorRow(a)
  local ta = {}
  for b = 0, 15 do
    local r, p, x, y = 0, 1, a, b
    for _ = 1, 4 do
      if (x % 2) ~= (y % 2) then r = r + p end
      x = floor(x / 2); y = floor(y / 2); p = p * 2
    end
    ta[b] = r
  end
  XOR4[a] = ta
end

-- Generator polynomial for 15 ECC symbols. It is a CONSTANT, so it is baked in
-- rather than recomputed on every build (that alone cost ~1.5x a whole
-- refresh() budget). Verified identical to a reference rs_gen(15).
local RS_GEN15 = { 1, 29, 196, 111, 163, 112, 74, 10, 105, 105, 139, 132, 151, 32, 134, 26 }

local QSIZE, QDATA, QEC = 29, 55, 15

-- One data codeword of the Reed-Solomon remainder. This is the most expensive
-- part of the build, so the PH_ECC phase runs it a few codewords at a time.
local function rs_step(res, i)
  local coef = res[i]
  if coef ~= 0 then
    local lc = LOG[coef]
    for j = 1, 16 do
      local g = RS_GEN15[j]
      if g ~= 0 then
        local k = i + j - 1
        res[k] = bxor8(res[k], EXP[(LOG[g] + lc) % 255])
      end
    end
  end
end

-- Encoding is split so no single step is expensive: putBits appends one value,
-- and packBits finishes off (terminator, padding, bits -> codewords).
local function putBits(bits, val, len)
  for i = len - 1, 0, -1 do bits[#bits + 1] = getbit(val, i) end
end

local function packBits(bits)
  local cap = QDATA * 8
  local term = cap - #bits
  if term > 4 then term = 4 end
  for _ = 1, term do bits[#bits + 1] = 0 end
  while (#bits % 8) ~= 0 do bits[#bits + 1] = 0 end
  local cw = {}
  for i = 1, #bits, 8 do
    local b = 0
    for j = 0, 7 do b = b * 2 + bits[i + j] end
    cw[#cw + 1] = b
  end
  local pad, pi = { 236, 17 }, 1
  while #cw < QDATA do cw[#cw + 1] = pad[pi]; pi = (pi == 1) and 2 or 1 end
  return cw
end

-- one blank row (the PH_MATRIX phase fills the 29 rows a few at a time)
local function q_blankRow(m, f, y)
  local my, fy = {}, {}
  for x = 0, QSIZE - 1 do my[x] = false; fy[x] = false end
  m[y], f[y] = my, fy
end

local function q_set(m, f, x, y, d) m[y][x] = d; f[y][x] = true end

local function q_finder(m, f, cx, cy)
  for dy = -4, 4 do for dx = -4, 4 do
    local xx, yy = cx + dx, cy + dy
    if xx >= 0 and xx < QSIZE and yy >= 0 and yy < QSIZE then
      local d = max(abs(dx), abs(dy))
      q_set(m, f, xx, yy, (d ~= 2 and d ~= 4))
    end
  end end
end

local function q_align(m, f, cx, cy)
  for dy = -2, 2 do for dx = -2, 2 do
    q_set(m, f, cx + dx, cy + dy, (max(abs(dx), abs(dy)) ~= 1))
  end end
end

local function q_format(m, f, mask)
  local data = 8 + mask
  local rem = data
  for _ = 1, 10 do rem = bxor(rem * 2, getbit(rem, 9) * 0x537) end
  local bits = bxor(data * 1024 + rem, 0x5412)
  for i = 0, 5 do q_set(m, f, 8, i, getbit(bits, i) == 1) end
  q_set(m, f, 8, 7, getbit(bits, 6) == 1)
  q_set(m, f, 8, 8, getbit(bits, 7) == 1)
  q_set(m, f, 7, 8, getbit(bits, 8) == 1)
  for i = 9, 14 do q_set(m, f, 14 - i, 8, getbit(bits, i) == 1) end
  for i = 0, 7 do q_set(m, f, QSIZE - 1 - i, 8, getbit(bits, i) == 1) end
  for i = 8, 14 do q_set(m, f, 8, QSIZE - 15 + i, getbit(bits, i) == 1) end
  q_set(m, f, 8, QSIZE - 8, true)
end

-- one column pair of the data-placement zig-zag (the PH_PLACE phase)
local function q_placeCol(m, f, cw, right, bit, total)
  local rc = right
  if rc <= 6 then rc = rc - 1 end
  local up = (getbit(rc + 1, 1) == 0)     -- constant for the whole column pair
  for vert = 0, QSIZE - 1 do
    local y = up and (QSIZE - 1 - vert) or vert
    local fy, my = f[y], m[y]
    for j = 0, 1 do
      local x = rc - j
      if (not fy[x]) and (bit < total) then
        my[x] = (getbit(cw[floor(bit / 8) + 1], 7 - (bit % 8)) == 1)
        bit = bit + 1
      end
    end
  end
  return bit
end

-- NOTE: the mask is hard-wired to 2 (condition: x % 3 == 0) and the PH_MASK
-- phase is specialised for it to save CPU. The generic per-cell q_maskcond()
-- was removed; changing QR_MASK alone would NOT change the output.

-- ---------------------------------------------------------------------------
--  The build, as a resumable state machine (no coroutines -- see the note at
--  the top of this section). J holds the in-progress job; qrStep() advances it
--  by about QR_SLICE ticks of work and returns "working" while more remains, or
--  the finished job on the frame that completes it.
-- ---------------------------------------------------------------------------
local PH_XOR, PH_GF, PH_MATRIX, PH_PATTERN, PH_ENCODE, PH_PACK,
      PH_ECC, PH_PLACE, PH_MASK, PH_RUNS, PH_DONE
    = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11

-- Cost of ONE unit of each phase, in the same "ticks" the EdgeTX watchdog counts
-- (1 tick = 200 VM instructions). MEASURED by running each phase alone under the
-- same instruction hook the radio uses -- NOT guessed. An earlier set of guessed
-- figures is exactly what put a frame over the limit on the radio. The scheduler
-- uses these to pack a frame without overshooting; re-measure if a phase changes.
local PH_COST = { 5, 12, 1, 16, 8, 16, 18, 9, 1, 2 }

-- THE FUNCTION PATTERNS ARE THE SAME IN EVERY CODE THIS WIDGET WILL EVER BUILD.
-- Version 3 and mask 2 are both fixed, so the finders, the timing lines, the
-- alignment block and the format bits land on identical cells every time -- and
-- PH_PLACE only writes cells the function mask leaves free. Computing them again
-- per rebuild cost 93 of the ~558 ticks of build work. Measured both ways with
-- the snapshot disabled: 26 frames and a 68-tick peak without it, 22 and 64 with
-- -- so it is worth four frames of wall clock (0.58 s on an MK3, 0.71 s on an
-- MK2) and four points of peak, on every single rebuild.
--
-- So the first build keeps a copy and every later one starts from it.
--   QTMPL   the post-pattern matrix. COPIED per build, never shared: PH_PLACE
--           and PH_MASK write into the matrix, so handing out the original would
--           corrupt every code after the first.
--   QFMASK  the function mask. SHARED, because nothing writes it after the
--           patterns are laid down -- the second q_format at the end of PH_MASK
--           only rewrites cells it already set to the same values.
-- Neither depends on the payload or the model, so neither is ever invalidated;
-- they outlive a model change on purpose (checkModel drops the JOB, not these).
local QTMPL, QFMASK = nil, nil

local J = nil                      -- current job, nil when idle
local function qrBusy() return J ~= nil end

local function qrBegin(text)
  if #text > 53 then return false end
  J = { text = text, i = 0,
        phase = tablesReady and PH_MATRIX or PH_XOR }
  return true
end

-- Returns "working" while more work remains, or the finished job when done.
local function qrStep()
  if J == nil then return nil end
  local budget, first = QR_SLICE, true
  while J.phase ~= PH_DONE do
    local ph = J.phase
    -- Never START a unit that will not fit; the only exception is the first unit
    -- of a frame, so an expensive phase still makes progress instead of stalling.
    local cost = PH_COST[ph]
    if not first and cost > budget then break end
    budget = budget - cost
    first = false

    if ph == PH_XOR then                       -- nibble-XOR table, 16 rows
      buildXorRow(J.i)
      J.i = J.i + 1
      if J.i > 15 then J.phase, J.i, J.gfx = PH_GF, 0, 1 end

    elseif ph == PH_GF then                    -- Galois field log/antilog, 256
      local x, i, n = J.gfx, J.i, 0
      while i <= 255 and n < 48 do
        EXP[i] = x; LOG[x] = i
        x = x * 2
        if x >= 256 then x = bxor(x, 285) end
        i = i + 1; n = n + 1
      end
      J.gfx, J.i = x, i
      if i > 255 then tablesReady = true; J.phase, J.i = PH_MATRIX, 0 end

    elseif ph == PH_MATRIX then                -- 29 blank rows
      if J.i == 0 then J.m, J.f = {}, {} end
      if QTMPL then
        local src, row = QTMPL[J.i], {}
        for x = 0, QSIZE - 1 do row[x] = src[x] end
        J.m[J.i] = row
      else
        q_blankRow(J.m, J.f, J.i)
      end
      J.i = J.i + 1
      if J.i >= QSIZE then
        if QTMPL then
          -- the patterns are already in the copied rows: skip PH_PATTERN
          J.f = QFMASK
          J.phase, J.i, J.bits = PH_ENCODE, 0, {}
          putBits(J.bits, 4, 4)                -- byte mode
          putBits(J.bits, #J.text, 8)          -- length
        else
          J.phase, J.i = PH_PATTERN, 0
        end
      end

    elseif ph == PH_PATTERN then               -- function patterns, 4 sub-steps
      local m, f = J.m, J.f
      if J.i == 0 then
        for i = 0, QSIZE - 1 do
          q_set(m, f, 6, i, i % 2 == 0)
          q_set(m, f, i, 6, i % 2 == 0)
        end
      elseif J.i == 1 then q_finder(m, f, 3, 3)
      elseif J.i == 2 then q_finder(m, f, QSIZE - 4, 3)
      else
        q_finder(m, f, 3, QSIZE - 4)
        q_align(m, f, 22, 22)
        q_format(m, f, QR_MASK)
      end
      J.i = J.i + 1
      if J.i > 3 then
        -- Keep what this cost, for every rebuild from here on. Done in one go
        -- rather than sliced: it is 29 rows, once per session, and it happens on
        -- the FIRST build, whose frames are the cheapest of any (there is no code
        -- on screen to draw yet).
        if QTMPL == nil then
          QTMPL = {}
          for y = 0, QSIZE - 1 do
            local s, d = m[y], {}
            for x = 0, QSIZE - 1 do d[x] = s[x] end
            QTMPL[y] = d
          end
          QFMASK = f
        end
        J.phase, J.i, J.bits = PH_ENCODE, 0, {}
        putBits(J.bits, 4, 4)                  -- byte mode
        putBits(J.bits, #J.text, 8)            -- length
      end

    elseif ph == PH_ENCODE then                -- text -> bit stream, 8 chars/unit
      local i, n = J.i, 0
      while i < #J.text and n < 8 do
        i = i + 1
        putBits(J.bits, string.byte(J.text, i), 8)
        n = n + 1
      end
      J.i = i
      if i >= #J.text then J.phase = PH_PACK end

    elseif ph == PH_PACK then                  -- bit stream -> data codewords
      J.cw = packBits(J.bits)
      J.bits = nil
      J.phase, J.i = PH_ECC, 0

    elseif ph == PH_ECC then                   -- Reed-Solomon, 55 codewords
      if J.i == 0 then
        local res = {}
        for k = 1, QDATA do res[k] = J.cw[k] end
        for k = QDATA + 1, QDATA + QEC do res[k] = 0 end
        J.res = res
      end
      local i, n = J.i, 0
      while i < QDATA and n < 6 do
        i = i + 1
        rs_step(J.res, i)
        n = n + 1
      end
      J.i = i
      if i >= QDATA then
        for k = 1, QEC do J.cw[QDATA + k] = J.res[QDATA + k] end
        J.res = nil
        J.phase, J.i, J.right, J.bit = PH_PLACE, 0, QSIZE - 1, 0
      end

    elseif ph == PH_PLACE then                 -- zig-zag data placement
      J.bit = q_placeCol(J.m, J.f, J.cw, J.right, J.bit, #J.cw * 8)
      J.right = J.right - 2
      if J.right <= 0 then J.phase, J.i = PH_MASK, 0 end

    elseif ph == PH_MASK then                  -- mask 2 == every third column
      local fy, my = J.f[J.i], J.m[J.i]
      for x = 0, QSIZE - 1, 3 do
        if not fy[x] then my[x] = not my[x] end
      end
      J.i = J.i + 1
      if J.i >= QSIZE then
        q_format(J.m, J.f, QR_MASK)
        J.runs = {}
        J.phase, J.i = PH_RUNS, 0
      end

    else                                       -- PH_RUNS: matrix -> draw runs
      local my, x, runs = J.m[J.i], 0, J.runs
      while x < QSIZE do
        if my[x] then
          local x2 = x
          while x2 < QSIZE and my[x2] do x2 = x2 + 1 end
          runs[#runs + 1] = { x, J.i, x2 - x }
          x = x2
        else
          x = x + 1
        end
      end
      J.i = J.i + 1
      if J.i >= QSIZE then J.phase = PH_DONE end
    end

    if budget <= 0 then break end
  end

  if J.phase ~= PH_DONE then return "working" end
  local done = J
  J = nil
  return done
end

-- ===========================================================================
--  STATE
-- ===========================================================================
-- The radio's own battery range, resolved once by widgetInit(). It lives OUTSIDE
-- the per-model state below: it describes the transmitter, not the model, so a
-- model change must not throw it away and fall back to the CFG guess.
local battRange = { min = nil, max = nil }

-- A FACTORY, not a literal, because every field below belongs to ONE model: its
-- home point, its flight, its QR code, its sensor readings. Switching models has
-- to start from nothing rather than inherit the last model's flight (see
-- checkModel). Closures capture the `st` VARIABLE, so reassigning it here is seen
-- by all of them.
local function newState() return {
  hasFix = false, sats = 0, satsKnown = false, satsOk = false, gpsKnown = false,
  lat = 0, lon = 0,
  stale = false,   -- RF link down: model-sourced readings are frozen, gray them
  spdKmh = 0, hdg = 0,
  -- altFC is the INPUT (the FC's altitude, datum unknown); altMsl is the OUTPUT
  -- (the sea-level figure to display, nil until it can be justified). Keeping
  -- them separate is deliberate: altMsl used to be both, which produced two
  -- runaway-divergence bugs where the rebuild fed on itself.
  altFC = nil, altMsl = nil, altRel = nil,
  fcINav = nil,    -- firmware family, proven from the flight-mode string (identifyFC)
  fcArdu = false,  -- narrower than fcINav: specifically ArduPilot (see AP_MODES)
  modeTxt = nil,   -- the MODE pill's text: the FC's flight-mode string, marker off
  -- Has a marker character ever been seen on THIS model? On Betaflight and INAV
  -- that is uninteresting, but on ArduPilot the disarm marker is OPT-IN
  -- (CRSF_FM_DISARM_STAR), and this is the only thing that tells "no marker =
  -- armed" apart from "no marker = the option is off". See readArmed.
  markerSeen = false,
  homeMsl  = nil,  -- launch elevation, captured disarmed, never shifted
  mslZeroed = false, -- FC re-datumed the GPS altitude at arm (BF 4.3-4.5)
  fcAltIsMsl = false, -- proven: this model's FC altitude reads MSL while disarmed
  mslGround = nil, -- settled MSL seen while DISARMED = the launch elevation
  mslCand = nil, mslCandT = nil,  -- a big disarmed step, on probation (MSL_SETTLE)
  altRefFC = nil, altPrevFC = nil, altFCAbs = false,
  homeSet = false, homePending = false, homeLat = 0, homeLon = 0,
  armed = false, armTime = nil, flightSec = 0, stillSince = nil, armWarn = false,
  armBlocked = false, -- the FC ITSELF refuses to arm (isArmingDisabled)
  flown = false,   -- has there been at least one take-off?
  tripKnown = false, -- has this flight EVER held a GPS lock? (gates the TRIP readout)
  lastLat = nil, lastLon = nil, trip = 0, distHome = nil,
  cog = nil,       -- course over ground, computed from consecutive GPS fixes
  maxDist = 0, maxAlt = 0, maxSpeed = 0,
  maxMsl = nil,    -- highest MSL reached; nil while MSL was never known
  rssi = nil, lq = nil, pwr = nil, rxbt = nil, mah = nil, telem = false,
  -- The ELRS RF mode INDEX, drawn as a packet rate in the strip's RATE cell.
  -- Named rfMode, not mode: st.modeTxt beside it is the FLIGHT mode, and one
  -- screen with two unrelated things called "mode" is how the strip cell came
  -- to be renamed from MODE to RATE in the first place.
  rfMode = nil,
  battPct = nil,
  battMin = battRange.min or CFG.BATT_MIN, battMax = battRange.max or CFG.BATT_MAX,
  -- The finished QR is kept ONLY as draw runs (see PH_RUNS): that is all the
  -- drawing needs, and holding the 29x29 boolean matrix as well would pin 29
  -- extra tables for nothing. qrRuns ~= nil IS the "we have a code" flag.
  qrRuns = nil,
  -- The position the CURRENT code encodes. nil = no code yet. This is what
  -- the rebuild trigger measures against (see CFG.QR_MIN_MOVE).
  qrLat = nil, qrLon = nil,
  L = nil,                          -- cached layout (see getLayout)
} end

local st = newState()

local C = {}   -- color palette (built in init)

-- ---------------------------------------------------------------------------
--  sensor access
-- ---------------------------------------------------------------------------
-- A sensor id is an INDEX into the CURRENT model's telemetry list -- NOT a stable
-- identifier for "the RSSI sensor". The same index means a different sensor on a
-- different model, and re-discovering sensors renumbers them on the same model. So
-- this cache is only ever valid for the sensor list it was built against: hold it
-- past a model switch and every reading silently comes from the wrong sensor.
-- checkModel() flushes it; validateField() catches renumbering underneath us.
local fieldIds  = {}
local fieldList = {}               -- cached names, so they can be re-checked
local fieldCur  = 0                -- round-robin cursor into fieldList

local function flushFields()
  fieldIds, fieldList, fieldCur = {}, {}, 0
end

local function rememberField(name, id)
  fieldIds[name] = id
  fieldList[#fieldList + 1] = name
end

local function sv(name)
  local id = fieldIds[name]
  if id == nil then
    local fi = getFieldInfo(name)
    if fi then id = fi.id; rememberField(name, id) else return nil end
  end
  return getValue(id)
end

-- Does this model HAVE such a sensor at all? Answered from the sensor list rather
-- than from a value, so it is meaningful with the link down -- a discovered sensor
-- exists in the model config whether or not anything is transmitting. Warms the
-- same id cache sv() uses, so asking costs nothing after the first hit.
local function svKnown(name)
  if fieldIds[name] ~= nil then return true end
  local fi = getFieldInfo(name)
  if fi then rememberField(name, fi.id); return true end
  return false
end

-- Re-resolve ONE cached name per frame, round-robin, and flush the lot if its id
-- has moved. This is the safety net under checkModel(): it catches renumbering
-- that no model change accompanies -- above all *Discover new sensors*, which
-- rebuilds the list in place and used to need a reboot before the widget agreed.
-- It also covers two models that share a name, which checkModel cannot tell apart.
-- One getFieldInfo per frame revalidates a dozen names about three times a second.
local function validateField()
  local n = #fieldList
  if n == 0 then return end
  fieldCur = fieldCur % n + 1
  local name = fieldList[fieldCur]
  local fi = getFieldInfo(name)
  if fi == nil or fi.id ~= fieldIds[name] then flushFields() end
end

local function svAny(list)
  for i = 1, #list do
    local v = sv(list[i])
    if v ~= nil then return v end
  end
  return nil
end

local function svNum(v) if type(v) == "number" then return v end return nil end

-- ---------------------------------------------------------------------------
--  MODEL CHANGE
--
--  Selecting another model does NOT reload this script: the Lua chunk stays
--  resident, so every module-level local survives -- the id cache, the flight,
--  the home point, the QR code. Reported from the field: Meteor (no GPS) ->
--  Explorer (GPS) -> Meteor left the second Meteor showing NO FIX with the link
--  statistics reading from whatever sensor now occupied the cached index.
--
--  Nothing here is salvageable across the switch, so everything model-scoped is
--  thrown away and rebuilt from the new model's own sensors.
-- ---------------------------------------------------------------------------
local mdlSig  = nil                -- signature of the model we are configured for
local mdlName = ""                 -- its name, read once a frame for the header

local function modelSig()
  if not (model and model.getInfo) then return "" end
  local i = model.getInfo()
  if type(i) ~= "table" then return "" end
  mdlName = type(i.name) == "string" and i.name or ""
  -- Prefer a filename where the firmware offers one (newer EdgeTX): two models
  -- can share a name and a bitmap, but not a file. On 2.8 this degrades to
  -- name+bitmap, and validateField() is the backstop for the ambiguous case.
  return tostring(i.filename or "") .. "\0" .. mdlName .. "\0" .. tostring(i.bitmap or "")
end

local function checkModel()
  local sig = modelSig()
  if sig == mdlSig then
    validateField()                -- same model: just police the id numbering
    return false
  end
  mdlSig = sig
  flushFields()                    -- ids belong to the old model's sensor list
  st = newState()                  -- home, trip, timer, QR, readings: all its own
  J = nil                          -- abandon any half-built QR for the old fix
  return true
end

-- Turn whatever the heading sensor hands us into a COMPASS BEARING, 0..359,
-- clockwise from north. It does not arrive that way, and it is EdgeTX that
-- makes it messy rather than the flight controller.
--
-- The CRSF GPS frame defines heading as UNSIGNED, degrees x 100 (Betaflight
-- telemetry/crsf.c: "uint16_t GPS heading ( degree / 100 )"). EdgeTX reads it
-- SIGNED anyway -- telemetry/crossfire.cpp does
--     value = (*byte & 0x80) ? -1 : 0;
-- before shifting the two bytes in -- so the top bit is treated as a sign. Two
-- consequences, and they land in ranges that cannot overlap, so each is safe to
-- undo on its own:
--
--   * The sender is signed. u-blox reports heading-of-motion over -180..+180
--     and Betaflight carries it in an int16, so a westerly course arrives as a
--     negative number. EdgeTX's sign extension gives it back intact: -31 really
--     does mean 31 degrees west of north, i.e. 329. Range: -180..0.
--
--   * The sender is unsigned. Anything from 327.68 deg up has bit 15 set, so
--     EdgeTX turns it into a large negative: 32768..35990 centidegrees come out
--     as -327.68..-295.46. Adding back the 65536 centidegrees the sign extension
--     removed restores it. Range: below -180.
--
-- Observed on a TX16S MK2 (EdgeTX 2.8.0): "HEADING -31 deg" parked on the
-- ground. Anything already in 0..359 passes through untouched.
local function compassDeg(h)
  if h < -180 then h = h + 655.36 end   -- undo the sign-extended uint16
  h = h % 360                           -- Lua's % follows the divisor's sign
  return h
end

-- ---------------------------------------------------------------------------
--  read telemetry into state
-- ---------------------------------------------------------------------------
local function readSensors()
  -- BEFORE anything is read: are these sensors even this model's? Runs from the
  -- background path too, so a model switch is noticed whether or not the widget's
  -- screen happens to be the one showing.
  checkModel()

  -- ---------------------------------------------------------------------------
  -- LINK STATS FIRST, because they decide whether anything else can be believed.
  --
  -- When telemetry stops, EdgeTX does NOT hand Lua the last reading: every
  -- telemetry source reads back as integer 0 (api_general.cpp, luaGetValueAndPush
  -- -- "telemetry not working, return zero for telemetry sources"). The values are
  -- still in the radio, merely flagged old by telemetryInterrupt10ms()'s
  -- setOld(), but a script cannot see them. So a naive re-read every frame does
  -- not freeze the display, it ZEROES it -- and a zeroed GPS table is not a table
  -- at all, which used to drop the whole screen to "--" the instant a battery was
  -- unplugged. Everything model-sourced below is therefore held explicitly.
  --
  -- None of these is ever legitimately zero either: a transmitting radio is not
  -- at 0 mW, RF mode 0 is not a packet rate, a connected pack is not at 0.0 V and
  -- 0 dBm would be an extremely STRONG signal.
  local function fresh(v) if v ~= nil and v ~= 0 then return v end return nil end

  local a, b = fresh(svNum(sv("1RSS"))), fresh(svNum(sv("2RSS")))
  local rssiNow = nil
  if a and b then rssiNow = max(a, b) else rssiNow = a or b end

  -- LINK QUALITY stays live: 0% is not a false reading, it is precisely how a
  -- dead link looks, and that is worth seeing.
  st.lq = svNum(sv("RQly"))

  -- STALE = the RF link is down, so every reading that comes FROM THE MODEL is
  -- now a frozen last-known value rather than live. Judge this from the LINK
  -- STATS alone -- they are the only sensors whose zero is itself the answer. If
  -- the radio has no link sensors at all we cannot know, so never claim staleness.
  -- svKnown, not sv: this asks whether the sensor EXISTS, which is a question for
  -- the model's sensor list, and a value read cannot distinguish "absent" from
  -- "present and reading zero" -- which is the state we are trying to detect.
  local linkKnown = svKnown("RQly") or svKnown("1RSS") or svKnown("2RSS")
  st.stale = linkKnown and (rssiNow == nil) and ((st.lq or 0) <= 0)

  -- These HOLD their last real reading; st.stale tells the UI to gray them.
  -- TX POWER and RATE hold too: they only ever reach the radio INSIDE the link
  -- statistics frame, so once that stops we cannot know them -- and ELRS dynamic
  -- power does change them behind our back (observed: the TX went 10 mW ->
  -- 1000 mW on link loss while the widget still showed 10 mW).
  st.rssi = rssiNow or st.rssi
  st.pwr  = fresh(svNum(sv("TPWR"))) or st.pwr
  st.rfMode = fresh(svNum(sv("RFMD"))) or st.rfMode
  st.rxbt = fresh(svNum(sv("RxBt"))) or st.rxbt

  -- ---------------------------------------------------------------------------
  -- MODEL-SOURCED READINGS. Skipped entirely while the link is down so they keep
  -- their last real values instead of being overwritten with zeros. Position,
  -- satellites, speed, heading and altitude then all freeze together, which is
  -- exactly what you want when a battery has just been ripped out mid-flight.
  -- Does this model have a GPS sensor AT ALL? Deliberately OUTSIDE the block
  -- below: a model's sensor list does not depend on the link, and this has to be
  -- answerable with the battery out -- otherwise every model looks GPS-less until
  -- the first packet arrives, and the QR card tells a fully equipped quad that it
  -- has no GPS. Tested by sensor EXISTENCE, never by value: before the first fix
  -- the sensor is present but reads empty, which is "no data yet", not "no GPS".
  st.gpsKnown = svKnown("GPS")

  if not st.stale then
    -- The satellite count is a QUALITY signal, not proof of a fix. Distinguish
    -- "the sensor does not exist" (unknown) from "the sensor says zero" --
    -- treating a missing sensor as 0 used to veto a perfectly good position and
    -- left the whole widget stuck on NO GPS.
    local satRaw = svNum(svAny(CFG.SAT_SENSORS))
    st.satsKnown = satRaw ~= nil
    st.sats = satRaw and floor(satRaw + 0.5) or 0
    st.satsOk = (not st.satsKnown) or (st.sats >= CFG.MIN_SATS)

    -- Valid coordinates are what makes a fix. "0,0" is what a GPS reports before
    -- it has one, so reject that explicitly. A known-zero satellite count also
    -- means no fix; an UNKNOWN count must not veto anything.
    local gps = sv("GPS")
    local fix = (type(gps) == "table") and (gps.lat ~= nil) and (gps.lon ~= nil)
                and not (gps.lat == 0 and gps.lon == 0)
                and ((not st.satsKnown) or st.sats >= 1)
    st.hasFix = fix
    if fix then st.lat = gps.lat; st.lon = gps.lon end

    st.spdKmh = (svNum(svAny(CFG.SPD_SENSORS)) or 0) * CFG.SPEED_TO_KMH
    -- =====================================================================
    --  ONE FC ALTITUDE, whatever this radio happens to call it.
    --
    --  EdgeTX RENAMED the CRSF GPS altitude in 2.12.0. Same frame, same bytes,
    --  same decode -- only the sensor's NAME changed, which is why one aircraft
    --  presents differently on two radios. From the crossfireSensors table in
    --  radio/src/telemetry/crossfire.cpp:
    --
    --    2.8 - 2.11   {GPS_ID,      4, STR_SENSOR_ALT,    UNIT_METERS, 0}
    --                 {BARO_ALT_ID, 0, STR_SENSOR_ALT,    UNIT_METERS, 2}
    --    2.12+     CS(GPS_ID,      4, STR_DEF(STR_SENSOR_GPSALT), UNIT_METERS, 0)
    --              CS(BARO_ALT_ID, 0, STR_DEF(STR_SENSOR_ALT),    UNIT_METERS, 2)
    --
    --  Both releases decode it identically --
    --  processCrossfireTelemetryValue(GPS_ALTITUDE_INDEX, value - 1000) -- so
    --  "GAlt" on 2.12+ and "Alt" on 2.8-2.11 are the SAME NUMBER. Verified in
    --  the source: v2.11.0 contains no STR_SENSOR_GPSALT at all, v2.12.0 does.
    --
    --  What is NOT the same: on 2.12+ `Alt` is BARO_ALT_ID, a different frame at
    --  2 decimals. So the rule keys on PRESENCE, never on the name:
    --
    --    GAlt present -> that is the GPS altitude. An `Alt` beside it is the
    --                    BAROMETER, a different quantity, and is not used: the
    --                    height and the MSL figure are then derived from one
    --                    source, so they cannot disagree with each other.
    --    GAlt absent  -> `Alt` is the only altitude this model sends, and on
    --                    2.8-2.11 it IS that same GPS field under its old name.
    --
    --  ONE input, therefore ONE set of guards. This used to be two fields
    --  (altMsl from GAlt, altRelFC from Alt) down two separate paths, so the
    --  jump detector and the GPS cross-check ran on an MK2 and not on an MK3 --
    --  for the same quad, same telemetry. See Tests/disarm_race_repro.py.
    --
    --  2.8-2.11 WITH a barometer is unresolvable, and always was: EdgeTX writes
    --  both frames to the same `Alt` sensor (the two STR_SENSOR_ALT rows above),
    --  so nothing downstream of EdgeTX can separate them either.
    -- =====================================================================
    local gpsRaw  = svNum(svAny(CFG.ALT_MSL_SENSORS))   -- GAlt: GPS altitude
    local baroRaw = svNum(svAny(CFG.ALT_REL_SENSORS))   -- Alt: baro, or the same
                                                        -- GPS field on 2.8-2.11
    local altRaw = gpsRaw
    if altRaw == nil then altRaw = baroRaw end
    st.altFC = altRaw and (altRaw * CFG.ALT_TO_M) or nil
    -- The VALUE is unified above; its PROVENANCE is not, and that difference is
    -- real. A sensor called `GAlt` is EdgeTX telling us the number came from
    -- GPS_ID sub-field 4 -- so it is a sea-level altitude by construction, and
    -- needs no further proof. `Alt` says no such thing: on 2.12+ it is the
    -- barometer and on 2.8-2.11 it is whichever frame arrived, so a reading from
    -- it has to EARN the MSL label at runtime (the disarmed-geometry test below).
    -- Erasing that distinction cost the MSL line at every field under
    -- ALT_JUMP_M, because a 40 m elevation cannot pass a >100 m test.
    if gpsRaw ~= nil and not st.fcINav then st.fcAltIsMsl = true end
    -- INAV sends ONE altitude and it is height above the position estimator's
    -- origin -- getEstimatedActualPosition(Z) in its telemetry/crsf.c, unchanged
    -- from 4.0.0 through 9.0.0. That is a RELATIVE reading at every moment, armed
    -- or not, which is why an INAV model reads 0 m on the ground however high the
    -- field is, and why it never re-datums at arm the way Betaflight does. There
    -- is no MSL anywhere in INAV's CRSF telemetry, so the reading may never be
    -- promoted to the MSL line however absolute it looks. (Rule 1 -- never show
    -- what cannot be known.) The single input above is unaffected: the height
    -- above take-off is still altFC minus the reference taken at arming.
    st.hdg    = compassDeg(svNum(svAny(CFG.HDG_SENSORS)) or 0)
    -- mAh drawn belongs HERE, not with the link statistics above, and it must
    -- NOT go through fresh(): that helper reads 0 as "no reading", which is
    -- right for an RSSI or a voltage but wrong for a battery that has simply
    -- not been flown yet. Sitting in this block it is skipped entirely while the
    -- link is down, so it holds its last value without ever mistaking a genuine
    -- zero for a dropout.
    st.mah    = svNum(svAny(CFG.MAH_SENSORS)) or st.mah
  end

  -- "is the model actually talking to us?" -- drives the ARM hold.
  st.telem = (rssiNow ~= nil) or ((st.lq or 0) > 0)

  -- radio's own battery
  local bv = getValue("tx-voltage")
  if type(bv) == "number" and bv > 0 then
    local p = (bv - st.battMin) / (st.battMax - st.battMin) * 100
    st.battPct = (p < 0) and 0 or ((p > 100) and 100 or p)
  else
    st.battPct = nil
  end
end

-- ---------------------------------------------------------------------------
--  home / arm / trip state machine
-- ---------------------------------------------------------------------------
local function coordQR(v)   return string.format("%." .. CFG.QR_PREC   .. "f", v) end
local function coordDisp(v) return string.format("%." .. CFG.DISP_PREC .. "f", v) end

-- "GPS LOCK" on the pill: a fix AND at least MIN_SATS satellites. This is the
-- single gate for everything derived from position -- the QR, the coordinate
-- readout and every flight figure. A 1-satellite fix can be kilometers out, so
-- publishing anything from one (least of all a 7-decimal coordinate) would state
-- a precision we do not have.
local function gpsLock() return st.hasFix and st.satsOk end

-- ---------------------------------------------------------------------------
--  Flight-mode string: arm state AND firmware family
-- ---------------------------------------------------------------------------
-- Betaflight and INAV both send the flight mode over CRSF as a short string, and
-- both encode the arm state in it -- but by OPPOSITE conventions, which is why
-- the same code cannot simply be pointed at an INAV model.
--
-- BETAFLIGHT (telemetry/crsf.c, crsfFrameFlightMode) writes the bare mode string
-- ("ACRO", "ANGL", "RTH", ...) and appends ONE marker character, but only when it
-- is both disarmed and not in failsafe:
--     '*' = ready to arm
--     '!' = arming disabled -- whatever isArmingDisabled() is currently latching
--           (throttle up, no gyro calibration, a failed sensor, an arming switch
--           already on at boot...). NOTE it is not about GPS: stock Betaflight
--           arms perfectly happily without a fix.
--     '?' = GPS rescue unavailable, but still armable
-- So on Betaflight the MARKER is the arm signal and the mode name is decoration.
--
-- INAV never appends anything. It picks the string from one of two sets instead:
-- armed, it names the flight mode; disarmed, it can say only one of three things.
-- Read Betaflight-style, every INAV string looks unmarked and therefore armed --
-- which is exactly what happened on the bench: an INAV model sitting disarmed
-- sent "OK", and the pill said ARMED (Swordfish/INAV 6.1.0, 2026-07-29).
--
-- Checked against INAV 4.0.0, 5.1.0, 6.1.0, 7.1.0, 8.0.0 and 9.0.0/master, and
-- against Betaflight 4.3.0, 4.5.0 and master. The disarmed set below is
-- unchanged across every one of those INAV releases.
--
--   OK    ready to arm
--   WAIT  GPS arming safety on, and no fix or no home fix yet
--   !ERR  arming disabled for some other reason
--
-- Betaflight has "WAIT" too (4.3+), and had "!ERR" up to 4.3 -- but it only ever
-- sends them DISARMED, which is precisely when it appends a marker. It transmits
-- "WAIT*", never a bare "WAIT". A BARE one of these three is therefore INAV, with
-- no overlap on any version of either firmware.
local INAV_DISARMED = { OK = true, WAIT = true, ["!ERR"] = true }

-- The mode name that really means "the FC will not let you arm" -- worth amber.
-- Keyed on the name with any Betaflight marker already stripped, because both
-- firmwares use this word and mean the same thing by it: `isArmingDisabled()`.
-- (Betaflight only sends it up to 4.3; 4.5 dropped the string and master signals
-- the same condition with the '!' marker instead.)
--
-- "WAIT" IS DELIBERATELY NOT HERE, and must not be added back. It reads like a
-- warning and is not one. Both firmwares send it for `no GPS fix OR no home point
-- yet` -- and on Betaflight the home point is established inside `tryArm()`
-- (`GPS_reset_home_position()`, verified in 4.5.0 `fc/core.c`), so it is not
-- clearable before the first arm of a session no matter how many satellites
-- arrive. Treating it as a warning painted every Betaflight model amber from
-- power-up until its first take-off -- exactly the window the pilot is looking at
-- the widget -- while the GPS pill beside it said GPS LOCK in green. Measured on
-- the Explorer/MK2 2026-07-28: 6 then 12 satellites, locked, `FM` stuck at
-- "WAIT*" throughout, and the quad armed perfectly normally; one arm/disarm cycle
-- turned it into "STAB*" and the pill went gray.
--
-- It is redundant as well as wrong: "have we got a usable fix?" is a question the
-- widget already answers for itself from the satellite count and position, which
-- is the more accurate answer because it does not depend on the FC's home-point
-- bookkeeping. See the armWarn line in updateLogic.
local FM_BLOCKED = { ["!ERR"] = true }

-- Modes only INAV has. Not needed to recognize a disarmed model -- the table
-- above does that on the first frame, and disarmed is how a model starts -- but
-- these identify the firmware when the widget comes up with the model ALREADY
-- flying (a mid-flight model or screen change). Betaflight's own additions
-- (POSH, ALTH, CHIR, PASS, STAB) are deliberately absent: they prove Betaflight,
-- which the marker already proves more cheaply.
-- LAND sits in INAV's disarmed chain on 7.x and in its armed chain on 8.x/9.x.
-- It is listed here as armed because that is what it means in flight, and
-- claiming DISARMED during a fixed-wing autoland would be the worse error.
local INAV_ARMED = {
  HRST = true, HOLD = true, CRUZ = true, CRSH = true, WP   = true, AH   = true,
  ANGH = true, LOTR = true, TURT = true, WRTH = true, GEO  = true, LAND = true,
}

-- ---------------------------------------------------------------------------
--  ARDUPILOT mode names -- Mode::name4(), the exact string that reaches the
--  radio. The chain is: the vehicle calls
--      notify.set_flight_mode_str(flightmode->name4())   (ArduCopter/mode.cpp)
--  into a char[5] (AP_Notify.h -- four characters plus the terminator), and
--  AP_CRSF_Telem.cpp calc_flight_mode() sends it verbatim. Used ONLY to
--  recognize the firmware; altitude needs no ArduPilot path, because it sends the
--  GPS's own location.alt over the standard CRSF GPS frame -- genuine MSL, never
--  re-datumed at arm, the same shape as Betaflight master/5.x -- so an ArduPilot
--  model lands in exactly the same "not INAV" bucket as a Betaflight one.
--
--  GENERATED FROM SOURCE, NOT BY HAND. It is every name4() in ArduCopter,
--  ArduPlane, Rover and ArduSub master (51 of them) MINUS every name any other
--  firmware also sends. That subtraction is the whole safety property, because a
--  name shared with another firmware would misidentify it:
--
--  "EVERY OTHER FIRMWARE" INCLUDES EVERY VERSION OF IT. Betaflight renamed its
--  whole ladder after 4.5 -- STAB became ANGL, MANU became PASS, and ALTH/POSH/
--  CHIR appeared -- so master's list is NOT the set of names Betaflight sends.
--  The names below are the union across bf_crsf.c (master) and the 4.3/4.4/4.5
--  reference copies:
--
--    ACRO   sent by Betaflight (its DEFAULT, `const char *flightMode = "ACRO"`)
--           AND by INAV.
--    ALTH   sent by Betaflight master.
--    POSH   sent by Betaflight master.
--    STAB   sent by Betaflight 4.3-4.5 -- their name for ANGLE mode, which is
--           most pilots' everyday mode on the versions most pilots are flying.
--    HOLD   sent by INAV.
--    LAND   sent by INAV.
--    MANU   sent by INAV, and by Betaflight 4.3-4.5 for PASSTHRU. Two independent
--           reasons, either one sufficient. This is the dangerous class:
--           misreading an INAV plane in MANUAL as ArduPilot would let the MSL
--           machinery loose on INAV's relative altitude and FABRICATE a sea-level
--           figure. Rule 1.
--
--  Getting this wrong is not theoretical, and all three of these shipped in some
--  form: ACRO and MANU were in the contributed version of this table, and STAB
--  survived our own first review because the collision check read master alone.
--  ACRO made a Betaflight quad joined mid-flight read DISARMED; STAB did the same
--  to a 4.5 quad in ANGLE; MANU would have put a false MSL on an INAV plane. All
--  pinned by ardupilot_test.
--
--  Losing seven names costs nothing: 44 remain, every vehicle passes through
--  AUTO/LOIT/RTL/GUID and the rest, so identification arrives on the next mode
--  change at the latest. RTL appears twice on purpose -- Copter and Plane pad it
--  to four bytes as "RTL " while Rover sends "RTL".
--
--  To regenerate after an ArduPilot release: Tests/ardupilot_modes.py.
local AP_MODES = {
  ALND = true, AROT = true, ATUN = true, AUTO = true, AVOI = true, BRAK = true,
  CIRC = true, CRUS = true, DETE = true, DOCK = true, DRIF = true, FBWA = true,
  FBWB = true, FHLD = true, FLIP = true, FOLL = true, GNGP = true, GUID = true,
  INIT = true, L2QL = true, LOIT = true, PHLD = true, QACO = true, QATN = true,
  QHOV = true, QLND = true, QLOT = true, QRTL = true, QSTB = true, RTL = true,
  ["RTL "] = true, SMPL = true, SPRT = true, SRTL = true, STER = true, STRK = true,
  SURF = true, SYSI = true, THML = true, THRW = true, TKOF = true, TRAN = true,
  TRTL = true, ZIGZ = true,
}

-- One marker character, and never part of a mode name except in "!FS!".
local function armMarker(fm)
  if fm == "!FS!" then return nil end
  local last = string.sub(fm, -1)
  if last == "*" or last == "!" or last == "?" then return last end
  return nil
end

-- Which firmware is this model running? Sticky once proven, because the answer
-- decides whether the altitude sensor may be read as MSL at all, and that must
-- not flip between frames. Cleared with the rest of the state on a model change,
-- so it is re-proven per model rather than per session.
local function identifyFC(fm)
  if st.fcINav ~= nil then return end                    -- already settled
  -- Strip a marker before matching AP_MODES: ArduPilot's own opt-in marker is
  -- the same '*' byte Betaflight uses, so a starred mode ("STAB*") still has to
  -- match its bare name. INAV is matched on the WHOLE string because INAV never
  -- appends anything -- a marker rules it out by itself.
  local mark = armMarker(fm)
  local base = (mark ~= nil) and string.sub(fm, 1, -2) or fm
  if AP_MODES[base] then
    st.fcArdu = true
    st.fcINav = false          -- same altitude bucket as Betaflight, see AP_MODES
  elseif INAV_DISARMED[fm] or INAV_ARMED[fm] then
    st.fcINav = true
    -- readSensors runs a frame ahead of this, so an INAV model's relative
    -- altitude has already been through the MSL machinery once. Everything it
    -- concluded came from a reading that was never MSL: drop it rather than
    -- carry it into the flight.
    st.altMsl,  st.mslGround, st.mslCand,   st.mslCandT = nil, nil, nil, nil
    st.homeMsl, st.maxMsl,    st.fcAltIsMsl, st.mslZeroed = nil, nil, false, false
  elseif mark ~= nil then
    st.fcINav = false                                    -- Betaflight-style marker
  end
end

-- The model's REAL arm state, or nil when nothing authoritative is available.
-- Returns state ("armed" / "disarmed" / "hold"), warn.  nil state = no source at
-- all. `warn` means the FC is unhappy: arming blocked, or in failsafe.
local function readArmed()
  local fm = svAny(CFG.ARM_SENSORS)
  if type(fm) ~= "string" or fm == "" then fm = nil end
  -- Identify BEFORE the ARM_MODE branch: a pilot who arms from a radio switch
  -- still needs the altitude routed correctly for their firmware.
  if fm ~= nil then identifyFC(fm) end

  -- The MODE pill's text, computed before every early return below so that all
  -- of them -- including the radio-switch path and the failsafe path -- leave it
  -- set. It is the FC's string VERBATIM except for the arming marker, which is a
  -- separate field the FC appends and which the ARM pill has already consumed.
  -- No translation: "!FS!" stays "!FS!". The widget does not know a better word
  -- for what the flight controller just said about itself.
  --
  -- Living inside readArmed is what makes the pill HOLD on a dropout: updateLogic
  -- only calls this while st.telem, so a dead link cannot rewrite the string, and
  -- the pill keeps its last value like the two pills beside it. (drawHeader grays
  -- it while stale -- but only when it would have been blue. See there.)
  if fm == nil then
    st.modeTxt = nil                             -- no FM sensor on this model
  else
    local t = (armMarker(fm) ~= nil) and string.sub(fm, 1, -2) or fm
    -- ArduPilot pads name4() to four bytes, so Copter and Plane send "RTL "
    -- where Rover sends "RTL". Trim it, or the pill draws a phantom character
    -- and MODE_ALERT misses the padded spelling.
    while string.sub(t, -1) == " " do t = string.sub(t, 1, -2) end
    -- Guard, not a policy: everything all three firmwares send is already four
    -- characters or fewer. This is what keeps a firmware we have never seen from
    -- overrunning a pill whose width was fixed at layout time.
    if string.len(t) > 4 then t = string.sub(t, 1, 4) end
    if t == "" then t = nil end
    st.modeTxt = t
  end

  if CFG.ARM_MODE ~= "auto" then                 -- an explicit radio switch wins
    local v = svNum(sv(CFG.ARM_MODE))
    if v ~= nil then return (v > 256) and "armed" or "disarmed", false end
    return nil, false
  end
  if fm == nil then return nil, false end

  -- FAILSAFE carries no marker on either firmware, so the string genuinely
  -- cannot say whether the model is armed. Must be tested BEFORE the marker
  -- check: "!FS!" ends in '!' too, but there it is part of the mode name.
  if fm == "!FS!" then return "hold", true end

  local mark = armMarker(fm)
  if mark ~= nil then
    -- Betaflight, and the marker is only ever written while DISARMED.
    --   '!' arming disabled          -> warn
    --   '?' GPS rescue unavailable   -> still armable, so NOT a warning
    --   '*' ready to arm             -> no warning
    -- ...with one exception for the mode NAME: Betaflight 4.3 has no '!' marker
    -- (it writes '*' unconditionally when disarmed) and signals arming-disabled
    -- as "!ERR*" instead. "WAIT*" is NOT such a case -- see FM_BLOCKED.
    --
    -- ArduPilot takes this branch too: with CRSF_FM_DISARM_STAR enabled it sends
    -- '*', and only while disarmed. A marker of any kind, on any firmware, is
    -- standing proof that the marker convention is live on this model -- which is
    -- the only thing that makes the no-marker case below mean ARMED rather than
    -- "the option is switched off".
    st.markerSeen = true
    return "disarmed", mark == "!" or FM_BLOCKED[string.sub(fm, 1, -2)] == true
  end
  -- No marker. On Betaflight and INAV this is unambiguous: INAV never marks, and
  -- Betaflight marks only while disarmed, so no marker there IS armed.
  if INAV_DISARMED[fm] then return "disarmed", FM_BLOCKED[fm] == true end
  -- On ArduPilot it is NOT unambiguous, because the marker is opt-in
  -- (CRSF_FM_DISARM_STAR, see CFG.ARM_SENSORS): an unmarked mode name means
  -- either "armed" or "disarmed with the option off", and Rule 1 says an honest
  -- "no source" beats guessing between them -- returning nil hands the model to
  -- the ARM_MODE chain (a radio switch, then motion) instead of inventing an arm
  -- edge that would move home, the trip and the timer. Once a marked frame has
  -- been seen the option is proven on, and this reads exactly like Betaflight.
  if st.fcArdu and not st.markerSeen then return nil, false end
  return "armed", false
end

-- Last-resort guess when the model tells us nothing: take off / land by motion.
local function motionArmed(now)
  if not st.hasFix then return st.armed end      -- no data: hold the current state
  if st.armed then
    if st.spdKmh <= CFG.STILL_SPD then
      if st.stillSince == nil then st.stillSince = now end
      if (now - st.stillSince) >= CFG.LAND_STILL_T * 100 then return false end
    else
      st.stillSince = nil
    end
    return true
  end
  st.stillSince = nil
  -- Arm on MOVEMENT only. Distance-from-home must NOT be a trigger: once the
  -- model has flown away it is permanently far from home, so it would re-arm on
  -- the very next frame after landing and could never show DISARMED.
  return st.spdKmh >= CFG.ARM_SPEED
end

-- ---------------------------------------------------------------------------
--  HEIGHT ABOVE TAKE-OFF, and the MSL figure that goes beside it.
--
--  CALL ONLY WITH A LIVE LINK. readSensors stops refreshing st.altFC during a
--  dropout, so a frozen reading would be re-derived against a moving reference
--  every frame. Measured before the guard: a frozen 120 m climbed past 4 km in
--  six frames, gaining the launch elevation each time. A dropout has to FREEZE
--  the altitude; it is the number you walk out to the field with.
-- ---------------------------------------------------------------------------
local function deriveAltitude()
  -- ONE source, so ONE subtraction. altRefFC is whatever the FC read at the
  -- moment of arming -- the model was on the ground then, so that reading IS
  -- zero height, whether the FC reports relative (Betaflight zeroes at arm, so
  -- the reference is ~0 and this changes nothing) or absolute (this is what
  -- stops the card showing height above SEA LEVEL). The reference is kept
  -- honest across a datum change by the jump detector in updateLogic, which
  -- runs BEFORE this and shifts altRefFC by the same step -- so what the
  -- comments here call "above" is above in EXECUTION order while sitting
  -- further down the FILE.
  if st.altFC ~= nil then
    st.altRel = st.altFC - (st.altRefFC or 0)
  else
    st.altRel = nil
  end

  -- THE MSL FIGURE IS AN OUTPUT, computed here and nowhere else. It is only
  -- claimed when it can be justified, because a firmware reporting
  -- height-above-boot reads ~0 on the ground and calling that "0 m MSL" would be
  -- a confident falsehood.
  --
  -- Not on INAV at any time: its altitude is height above the estimator origin
  -- armed or not, so no amount of evidence makes it a sea-level figure.
  st.altMsl = nil
  if not st.fcINav then
    if st.armed and st.mslZeroed and st.homeMsl ~= nil and st.altRel ~= nil then
      -- The FC re-datumed at arm, so the raw reading is a height. The launch
      -- elevation was measured before arming and never moves: elevation + height
      -- is the honest answer. (Betaflight 4.3-4.5, flight/position.c.)
      st.altMsl = st.homeMsl + st.altRel
    elseif (st.fcAltIsMsl or st.altFCAbs) and st.altFC ~= nil then
      -- The reading is known absolute -- from the sensor's own name, the
      -- disarmed-geometry test, or the jump detector watching it revert. Real
      -- altitude beats anything derived, so use it as it came in.
      st.altMsl = st.altFC
      -- ...EXCEPT while a big disarmed step is still on probation. Believing the
      -- reading here and not below would contradict itself, and this is the
      -- window in which a re-datum arriving just ahead of the arm string would
      -- otherwise flash "0 m MSL". Hold the elevation we still stand behind.
      -- (This runs LAST, so it has to re-apply what the sampler decided.)
      if not st.armed and st.mslCand ~= nil and st.mslGround ~= nil then
        st.altMsl = st.mslGround
      end
    end
  end
end

local function updateLogic(now)
  -- ARM STATE. Evaluated every frame and edge-triggered, so it tracks the model
  -- both ways -- the old code only ever had a path INTO the armed state when
  -- arming from motion, which left the pill stuck on ARMED after landing.
  -- No telemetry means UNKNOWN, not disarmed: the model may well still be
  -- flying (brief failsafe, antenna blip). Claiming DISARMED there would be
  -- plainly false, so hold the last known state until the model talks again.
  if st.telem then
    local state, warn = readArmed()
    local armed
    if state == nil then armed = motionArmed(now)   -- no real signal: guess
    elseif state == "hold" then armed = st.armed    -- failsafe: keep last known
    else armed = (state == "armed") end
    if armed ~= st.armed then
      st.armed = armed
      if armed then                               -- take-off: start a fresh flight
        st.armTime, st.trip, st.flightSec = now, 0, 0
        st.flown = true                           -- there is now a flight to show
        st.tripKnown = false                      -- ...but not yet a measurable one
        st.lastLat, st.lastLon = st.lat, st.lon
        st.cog = nil                              -- last flight's course is not this one's
        st.maxDist, st.maxAlt, st.maxSpeed = 0, 0, 0
        st.maxMsl = nil          -- nil, not 0: sea level is a real altitude
        -- HOME IS SET HERE, at the moment of take-off, and then frozen for the
        -- whole flight. Re-arming re-homes, so moving to a new launch spot needs
        -- no power cycle. If there is no lock yet the capture is deferred to the
        -- first locked frame rather than recording a position we don't trust.
        st.homeSet = false
        st.homePending = true
        -- Reference for "height above take-off" from the FC's own altitude. The
        -- model is on the ground right now, so whatever it reads IS zero height,
        -- whether the FC reports relative (Betaflight zeroes at arm -> ~0, this
        -- changes nothing) or ABSOLUTE altitude (-> this is what stops the card
        -- showing height above SEA LEVEL).
        st.altRefFC = st.altFC
        -- Re-baseline the jump detector's previous sample TOO. Betaflight zeroes
        -- the baro altitude on the same arm event, and both telemetry frames can
        -- easily land inside a single refresh -- ~145 ms on an MK3, not the 30 ms
        -- this once assumed -- so the line above would take the new zero as the
        -- reference, and the detector below would then measure that very same drop
        -- against the OLD sample and subtract it a second time.
        -- Seeding it here makes this frame's step exactly 0, while leaving the
        -- detector free to catch a re-datum that arrives on any LATER frame (which
        -- is how the other ordering is handled). Without it, a 681 m -> 0 collapse
        -- coinciding with arming showed 681 m of altitude on the ground.
        st.altPrevFC = st.altFC
        st.mslZeroed = false     -- re-detect the GPS re-datum for this flight
        -- Seed the launch elevation NOW from the settled disarmed sample. The full
        -- capture below waits for a locked fix and runs later in this same frame,
        -- so until it does homeMsl is nil -- and every consumer of it, including
        -- the MSL readout, had nothing to work with. That blanked the MSL line for
        -- a frame or two at every take-off, which reads as a flicker. Nothing is
        -- actually unknown at this instant: the elevation was measured before
        -- arming and the model has not moved. (The capture below recomputes it the
        -- same way, so this only ever fills the gap.)
        st.homeMsl = st.mslGround
      else                                        -- landed
        st.armTime, st.stillSince = nil, nil
      end
    end

    -- WHOSE complaint is the amber? Two quite different things used to share it,
    -- and the pilot's next move differs, so the pill WORD separates them:
    --
    --   BLOCKED         the flight controller itself refuses to arm -- its own
    --                   isArmingDisabled(): throttle up, model not level,
    --                   calibration pending, arm switch already on. Something to
    --                   go and FIX. (Confirmed on the MK3 2026-07-29: throttle up
    --                   while disarmed produces exactly this, with a green lock.)
    --   DISARMED amber  the WIDGET's own warning: no GPS lock yet, so arming now
    --                   would cost the home point, and with it DISTANCE TO HOME
    --                   and height-above-take-off. Something to WAIT for. Only
    --                   raised on a model that actually has a GPS, or a GPS-less
    --                   one would sit amber forever.
    --
    -- Only a "disarmed" verdict can be blocked: failsafe reports "hold" and keeps
    -- the ARMED pill, where amber goes back to meaning failsafe alone. When both
    -- apply the FC wins the wording -- a lock arrives on its own, a raised
    -- throttle does not.
    st.armBlocked = (state == "disarmed") and warn == true
    st.armWarn = warn or (st.gpsKnown and not st.armed and not gpsLock())
  end

  -- FLIGHT-CONTROLLER ALTITUDE REFERENCE CHANGES.
  -- Some FCs start out reporting altitude relative to the arming point and then
  -- switch to absolute (MSL) once GPS altitude becomes trusted -- the reading
  -- teleports by hundreds of meters with the model sitting still. No aircraft
  -- changes height that fast between two telemetry frames, so a jump that large
  -- is a change of REFERENCE, not motion. Shift our own reference by the same
  -- amount: the displayed height then stays continuous across the switch.
  -- Skipped while the link is down, where a frozen reading would resume with a
  -- legitimately large change.
  local aFC = st.altFC
  if aFC ~= nil and not st.stale then
    if st.altPrevFC ~= nil and st.altRefFC ~= nil then
      local d = aFC - st.altPrevFC
      if d > CFG.ALT_JUMP_M or d < -CFG.ALT_JUMP_M then
        st.altRefFC = st.altRefFC + d
        -- Jumping UP to a big number means the source is now an ABSOLUTE
        -- altitude, so it doubles as the MSL readout when there is no GPS
        -- altitude sensor. Jumping back down means it is relative again.
        -- Never on INAV, whose altitude is relative by construction: a fast
        -- enough dive could clear ALT_JUMP_M between two frames, and reading
        -- that as "the sensor became absolute" would put a height on the MSL
        -- line. The re-baselining above still runs -- it is protective either
        -- way -- but it may not conclude anything about sea level here.
        st.altFCAbs = d > 0 and not st.fcINav
      end
    end
    st.altPrevFC = aFC
  elseif st.stale then
    st.altPrevFC = nil            -- do not judge a jump across a dropout
  end

  -- ===========================================================================
  --  THE ALTITUDE SENSOR RE-DATUMS AT ARM, and it is the MSL source either way.
  --
  --  Betaflight 4.3 / 4.4 / 4.5 put getEstimatedAltitudeCm() -- not the raw GPS
  --  altitude -- into the CRSF altitude field (telemetry/crsf.c), and
  --  flight/position.c switches what that means the instant you arm:
  --      DISARMED -> "most recent ASL GPS altitude"   (i.e. real MSL)
  --      ARMED    -> zeroedAltitudeCm, height above the arming point (>= 0)
  --  Betaflight master/5.x sends gpsSol.llh.altCm instead and never re-datums;
  --  both are handled, and which one you have is worked out below rather than
  --  assumed.
  --
  --  WHICH SENSOR this arrives as depends on the RADIO, not the aircraft: GAlt on
  --  EdgeTX 2.12+, Alt on 2.8-2.11 (verified 2026-07-28 -- the same Explorer
  --  showed GAlt only on an MK3 and Alt only on an MK2). readSensors has already
  --  collapsed that to the single st.altFC, so everything below is written once
  --  and cannot behave differently on the two radios. See single_alt_test, and
  --  disarm_race_repro for what it cost when it could.
  -- ===========================================================================
  --
  -- It is only CLAIMED as MSL where that can be justified, because a firmware
  -- reporting height-above-boot would read ~0 on the ground and calling that
  -- "0 m MSL" would be a confident falsehood. There are two justifications, and
  -- between them they cover the ground case the pilot actually wants.
  --
  -- ...and not on INAV, where the justifications below do not hold: its altitude
  -- is height above the estimator origin whether armed or not, so a disarmed
  -- model reading hundreds of meters is one sitting on a hill it took off from,
  -- not one reporting MSL. See readSensors.
  if st.altFC ~= nil and not st.fcINav
     and not st.stale and gpsLock() then
    local absolute
    if not st.armed then
      -- A DISARMED model is sitting on the ground, so its height above anything it
      -- has flown is zero BY DEFINITION. A reading of hundreds of meters therefore
      -- cannot be a height at all -- the only thing left for it to be is an
      -- absolute altitude. That is forced by the geometry, not guessed, and it is
      -- what puts the MSL line on the card before the first take-off.
      --
      -- Below ALT_JUMP_M nothing is claimed: at a field 40 m above the sea, "40"
      -- is equally consistent with 40 m of elevation and with 40 m of carrying a
      -- powered model uphill, and the widget does not choose between them. The
      -- first arming settles it either way (st.fcAltIsMsl).
      absolute = st.fcAltIsMsl or st.altFC > CFG.ALT_JUMP_M
    else
      -- ARMED, and this flight showed no re-datum: altRefFC was captured at
      -- take-off and homeMsl measured before it, so the two still agreeing means
      -- the sensor never zeroed and is reading absolute altitude throughout
      -- (Betaflight master/5.x sends gpsSol.llh.altCm and never re-datums). Both
      -- are frozen for the flight, so this cannot flicker as the model climbs.
      absolute = not st.mslZeroed and st.homeMsl ~= nil and st.altRefFC ~= nil
                 and st.homeMsl > CFG.ALT_JUMP_M
                 and abs(st.altRefFC - st.homeMsl) <= CFG.ALT_JUMP_M
    end
    if absolute then st.fcAltIsMsl = true end
  end
  -- The absolute-altitude candidate: the dedicated sensor where the radio has one,
  -- otherwise the FC altitude -- which is what lets the collapse below be SEEN the
  -- first time, before fcAltIsMsl is set.
  -- On INAV there is no candidate at all, and leaving this nil is what switches
  -- the whole MSL apparatus off: the launch-elevation sampling, the re-datum
  -- detection and the homeMsl capture are all gated on it, and none of them has
  -- anything to measure on a firmware that never reports an elevation.
  local mslNow = (not st.fcINav) and st.altFC or nil

  if not st.armed and mslNow ~= nil and not st.stale and gpsLock() then
    -- The launch elevation must be sampled while DISARMED -- the only time every
    -- firmware agrees the sensor means MSL. Reading it on the arm edge is too
    -- late: Betaflight has already re-datumed and the value is 0.
    --
    -- It can also be too late BEFORE the arm edge, which is subtler and is what
    -- actually bit. The re-datum happens on the FC's arm event, but the flight
    -- mode string and the GPS frame are separate CRSF frames arriving at
    -- different rates -- so the new zero can reach the radio FIRST. The widget
    -- still believes it is disarmed and samples ~0 as the launch elevation.
    -- homeMsl is then 0 and the MSL readout mirrors the height for the whole
    -- flight (MK3/Explorer, 2026-07-28: "0 m MSL" at arm, then 49 m of altitude
    -- beside "49 m MSL"). ONE such frame is enough.
    --
    -- So a big step is not believed until it PERSISTS. A disarmed model cannot
    -- move hundreds of meters between two frames; carried down a mountain road it
    -- descends a few meters per GPS frame and is tracked step by step. Only an
    -- instantaneous jump waits to be confirmed -- and a re-datum never is, because
    -- the arm arrives within a frame or two of it. Refusing the jump outright
    -- would be wrong: drive to a field 100 m lower without restarting the radio
    -- and the reference would be stuck at the old site forever.
    local g = st.mslGround
    if g == nil or abs(mslNow - g) <= CFG.ALT_JUMP_M then
      st.mslGround = mslNow
      st.mslCand, st.mslCandT = nil, nil
    elseif st.mslCand == nil or abs(mslNow - st.mslCand) > CFG.ALT_JUMP_M then
      st.mslCand, st.mslCandT = mslNow, now          -- start confirming
    elseif (now - st.mslCandT) >= MSL_SETTLE * 100 then
      st.mslGround = mslNow                          -- it held: a real move
      st.mslCand, st.mslCandT = nil, nil
    end
    -- While a step is on probation, DISPLAY the settled elevation as well. Not
    -- believing a reading and then putting it on the card would contradict itself
    -- -- and on a radio with a GAlt sensor the readout comes straight off that
    -- sensor, so the re-datum arriving before the arm string would flash "0 m MSL"
    -- for the frame or two in between. Hold the figure we still stand behind.
    if st.mslCand ~= nil and st.mslGround ~= nil then st.altMsl = st.mslGround end
  elseif st.armed and not st.mslZeroed and not st.stale
         and st.homeMsl ~= nil and mslNow ~= nil and st.armTime ~= nil
         and (now - st.armTime) <= ALT_ZERO_T * 100 then
    -- WHERE the reading landed, not HOW FAR it fell.
    --
    -- The launch elevation is already known (homeMsl, measured before arming), so
    -- after take-off the reading can only be sitting in one of two places: at the
    -- height above take-off, meaning the FC re-datumed, or at that height plus the
    -- launch elevation, meaning it did not. Those two are homeMsl apart, so
    -- whichever it is nearer settles it.
    --
    -- This replaced a test on the SIZE of the drop (> ALT_JUMP_M), which needed the
    -- field to be more than 100 m above the sea to work at all: at a 40 m field the
    -- re-datum went unnoticed and the MSL line mirrored the height for the whole
    -- flight. Comparing positions has no such floor -- and at genuine sea level the
    -- two candidates coincide, where being wrong costs nothing.
    -- The height is computed FRESH here, not taken from st.altRel: that still
    -- holds the previous frame's figure, and before the first take-off there is no
    -- reference yet, so it is the raw reading rather than a height. Feeding that in
    -- made arriving at a lower field look like a re-datum.
    local h = 0
    if st.altFC ~= nil and st.altRefFC ~= nil then h = st.altFC - st.altRefFC end
    if abs(mslNow - h) < abs(mslNow - (st.homeMsl + h)) then
      st.mslZeroed = true
      -- ...and THAT is the proof the disarmed reading was absolute. On a radio
      -- with no GPS-altitude sensor this is the only way to learn it, so remember
      -- it for the session: from now on the MSL line works on the ground too.
      st.fcAltIsMsl = true
    end
  end

  if st.hasFix then
    -- take-off capture (see the arm edge above): only ever from a locked fix
    if st.homePending and gpsLock() then
      st.homeLat, st.homeLon, st.homeSet = st.lat, st.lon, true
      -- ONE reference now: homeMsl, the launch point's REAL elevation, captured
      -- while still disarmed (when the sensor is honest MSL on every firmware)
      -- and NEVER shifted afterwards. There used to be a second one, homeAltM,
      -- that moved with the sensor's datum -- and that drift is exactly what
      -- turned a disarm-edge race into "MAX ALTITUDE 707 m" at a 713 m field.
      -- The height above take-off comes from altRefFC instead, which the jump
      -- detector keeps aligned with whatever datum the FC is currently using.
      -- Prefer the reading taken right now, but only if it still AGREES with the
      -- last disarmed sample. If it has leapt away, the FC re-datumed on the arm
      -- edge and the current value is no longer an elevation -- keep the disarmed
      -- one, which is the real launch height.
      -- ...and if the re-datum has ALREADY been detected above, never prefer the
      -- current reading, whatever the arithmetic says. At a 40 m field the
      -- re-datumed 0 is only 40 m from the disarmed sample -- inside ALT_JUMP_M --
      -- so this used to adopt it as the launch elevation and the whole flight's MSL
      -- came out 40 m low. The detection above already knows better by then.
      local g = st.mslGround
      if g ~= nil and mslNow ~= nil and not st.mslZeroed
         and abs(mslNow - g) <= CFG.ALT_JUMP_M then
        g = mslNow
      end
      st.homeMsl = g or mslNow
      st.homePending = false
    end


    if not st.stale then deriveAltitude() end

    if st.homeSet then
      st.distHome = distanceM(st.lat, st.lon, st.homeLat, st.homeLon)
    end

    -- trip + maxima while armed
    if st.armed then
      -- Has this flight ever been measurable? A trip of 0 is a real reading from a
      -- model that hovered, but only if we held a lock to measure it with -- so the
      -- flag is set by the LOCK, not by movement. It gates the readout for the rest
      -- of the flight, which is why losing the fix later does not erase the total.
      if gpsLock() then st.tripKnown = true end
      if st.lastLat then
        local step = distanceM(st.lat, st.lon, st.lastLat, st.lastLon)
        if step >= CFG.TRIP_MIN_STEP and step <= CFG.TRIP_MAX_STEP then
          st.trip = st.trip + step
          -- COURSE OVER GROUND, from the same two fixes the trip just accepted.
          -- The heading SENSOR is not trustworthy: the CRSF field is unsigned
          -- centidegrees, EdgeTX reads it signed, and at least one firmware
          -- sends it a factor of ten small (measured in flight: a true 18.6 deg
          -- outbound course read 1-3, and its 198.6 deg reciprocal read ~20).
          -- These two points are already jitter-filtered by TRIP_MIN_STEP, and
          -- they are the same data the distance and trip readouts are built
          -- from -- so the heading now agrees with the rest of the screen
          -- whatever the flight controller thinks its units are.
          st.cog = bearingDeg(st.lastLat, st.lastLon, st.lat, st.lon)
          st.lastLat, st.lastLon = st.lat, st.lon
        elseif step > CFG.TRIP_MAX_STEP then
          st.lastLat, st.lastLon = st.lat, st.lon
        end
      else
        st.lastLat, st.lastLon = st.lat, st.lon
      end
      -- compare AND store the same value: testing "(x or 0)" but assigning x
      -- would write a nil straight into the maximum.
      local dh = st.distHome or 0
      local ar = st.altRel or 0
      if dh > st.maxDist then st.maxDist = dh end
      if ar > st.maxAlt then st.maxAlt = ar end
      if st.spdKmh > st.maxSpeed then st.maxSpeed = st.spdKmh end
      -- Tracked from the MSL figure ITSELF rather than computed as
      -- homeMsl + maxAlt, so it stays right however that figure was arrived at --
      -- read from the sensor, or rebuilt after a re-datum. Left nil while MSL was
      -- never known, so the debrief shows no note instead of an invented zero.
      if st.altMsl ~= nil and (st.maxMsl == nil or st.altMsl > st.maxMsl) then
        st.maxMsl = st.altMsl
      end
    end
  end

  -- Only advance while armed. On disarm we simply stop updating, so the finished
  -- flight's duration STAYS on screen -- landing is exactly when you want to read
  -- it. The next arm sets armTime = now, which snaps this back to zero.
  if st.armed and st.armTime then
    st.flightSec = (now - st.armTime) / 100
  end
end

-- Kick off an incremental build of the QR for the CURRENT position.
-- This is the only heavy operation in the widget: the work happens in qrStep(),
-- one slice per frame, so no single refresh() blows the CPU budget.
--
-- The position being encoded is recorded HERE, at the start of the build rather
-- than at its end. It is what the next frame measures against, and a build takes
-- ~31 frames -- so recording it on completion would let the trigger fire again
-- for movement this build is already encoding.
local function captureQR()
  if not gpsLock() then return false end
  local txt = CFG.QR_URL .. coordQR(st.lat) .. "," .. coordQR(st.lon)
  if not qrBegin(txt) then return false end
  st.qrLat, st.qrLon = st.lat, st.lon
  return true
end

-- Called only when the screen is visible (never in background), so the QR never
-- burns CPU while you are looking at another telemetry page.
local function updateQR()
  -- EVENT-DRIVEN: rebuild when the model has moved, not on a timer. `qrBusy`
  -- is what keeps this bounded -- a build cannot be started while one is
  -- running, so the build duration is the rate limit and no minimum interval
  -- is needed. See CFG.QR_MIN_MOVE for why it is a distance and not a new fix.
  if gpsLock() and not qrBusy() then
    if st.qrLat == nil then
      captureQR()                      -- no code yet: build at the first lock
    elseif movedAtLeast(st.lat, st.lon, st.qrLat, st.qrLon, CFG.QR_MIN_MOVE) then
      captureQR()
    end
  end
  -- Advance an in-progress build by ONE slice, and publish it on the frame that
  -- finishes. (This was a stepQR() of its own: one caller, and a name one word
  -- order away from the qrStep() it wrapped, which is how the wrong one gets
  -- edited.)
  local r = qrStep()
  if r ~= nil and r ~= "working" then st.qrRuns = r.runs end
end

-- ---------------------------------------------------------------------------
--  formatting for display
-- ---------------------------------------------------------------------------
local function fmtTime(s)
  s = floor(s + 0.5)
  return string.format("%02d:%02d", floor(s / 60), s % 60)
end

-- Round FIRST, then pick the unit, so the small unit can never display a value
-- that has rounded up to the switch point (999.6 m must read "1.00 km", not "1000 m").
local function fmtDist(m)   -- returns value, unit
  if CFG.UNITS == "imperial" then
    local ft = floor(m * 3.28084 + 0.5)
    if ft < 5280 then return string.format("%d", ft), "ft"
    else return string.format("%.2f", ft / 5280), "mi" end
  else
    local mr = floor(m + 0.5)
    if mr < 1000 then return string.format("%d", mr), "m"
    else return string.format("%.2f", mr / 1000), "km" end
  end
end

local function fmtSpeed(kmh)
  if CFG.UNITS == "imperial" then return string.format("%d", floor(kmh * 0.621371 + 0.5)), "mph"
  else return string.format("%d", floor(kmh + 0.5)), "km/h" end
end

-- mAh drawn. Switches to Ah past four digits, the same way fmtDist moves from
-- meters to km: a 5-digit "12345mAh" is 62 px of a 65 px cell on 480x272, while
-- "12.3Ah" is 40. Round first, THEN pick the unit, so 9999.6 cannot print as
-- "10000mAh".
local function fmtMah(v)
  if v == nil then return "--" end
  local r = floor(v + 0.5)
  if r < 10000 then return string.format("%dmAh", r) end
  return string.format("%.1fAh", r / 1000)
end

-- The radio's wall clock, 24-hour. getDateTime() is registered unconditionally
-- in EdgeTX (api_general.cpp, opentxLib) so it is safe on 2.8 upwards, but guard
-- it anyway: a build without an RTC would hand back nothing useful.
local function clockHM()
  local d = getDateTime and getDateTime()
  if type(d) ~= "table" or d.hour == nil or d.min == nil then return "--" end
  return string.format("%02d:%02d", d.hour, d.min)
end

local function fmtAlt(m)
  if CFG.UNITS == "imperial" then return string.format("%d", floor(m * 3.28084 + 0.5)), "ft"
  else return string.format("%d", floor(m + 0.5)), "m" end
end

-- An ABSOLUTE altitude, for the MSL line. The geoid correction is applied here, at
-- the point of display, and nowhere else: everything upstream -- the launch
-- elevation, the re-datum detection, the maxima -- works in the flight
-- controller's own datum, where a constant offset cancels out of every difference
-- and could only introduce a place to get the sign wrong.
local function fmtMsl(m) return fmtAlt(m + CFG.MSL_OFFSET) end

-- ===========================================================================
--  DRAWING
-- ===========================================================================
local function buildColors()
  C.bg     = lcd.RGB(14, 17, 23)
  C.header = lcd.RGB(22, 27, 36)
  C.card   = lcd.RGB(28, 34, 46)
  C.card2  = lcd.RGB(37, 44, 59)
  C.text   = WHITE
  C.dim    = lcd.RGB(150, 160, 175)
  -- STALE readings are drawn in this instead of C.text: a plain "grayed out"
  -- look, the universal idiom for "not live". Deliberately NOT amber or red --
  -- those already mean "the flight controller is unhappy" on the ARMED pill, and
  -- a frozen reading is not an alarm, it is just old.
  C.stale  = lcd.RGB(122, 134, 152)
  C.label  = lcd.RGB(120, 132, 150)
  C.green  = lcd.RGB(46, 204, 113)
  C.blue   = lcd.RGB(52, 152, 219)
  C.amber  = lcd.RGB(241, 196, 15)
  C.purple = lcd.RGB(165, 105, 220)
  C.teal   = lcd.RGB(26, 188, 156)
  C.orange = lcd.RGB(230, 126, 34)
  C.red    = lcd.RGB(231, 76, 60)
  C.white  = WHITE
end

-- Text metrics. Pass the plain font flag (no color bits). Returns width, height,
-- where the height is the LINE BOX, not the glyph -- everything that stacks text
-- relies on that (see the notes in computeLayout).
--
-- There used to be a hand-rolled fallback here for a build without lcd.sizeText,
-- keyed on a table of font constants. It was worse than nothing twice over:
-- lcd.sizeText is present in 2.8.0, which is this widget's declared floor, so the
-- fallback could never run -- while its table indexed SMLSIZE/MIDSIZE/DBLSIZE/
-- XXLSIZE as KEYS, and a nil key raises "table index is nil" while the file is
-- still LOADING. That is the same crash F_STD guards against, except a fallback
-- that kills the widget outright is not a fallback. XXLSIZE was in there for a
-- font GPSQR never draws with.
local function textSize(s, font)
  return lcd.sizeText(s, font)
end

-- ELRS/CRSF RF-mode (RFMD) index -> packet-rate label, drawn in the strip's RATE
-- cell. (The cell was called MODE until the header gained a flight-MODE pill and
--  one screen could not have two things called that.) The index ranges are
-- distinct per firmware, so the raw value self-identifies what's installed:
--   1-14 = ELRS 3.x   |   20-33 = ELRS 4.x   |   100+ = ELRS 4.x Gemini/dual-band
local RF_MODE = {
  [1]="25Hz",  [2]="50Hz",  [3]="100Hz", [4]="100F",  [5]="150Hz", [6]="200Hz", [7]="250Hz",
  [8]="333F",  [9]="500Hz", [10]="D250", [11]="D500", [12]="F500", [13]="F1000", [14]="OFF",
  [20]="25Hz", [21]="50Hz", [22]="100Hz",[23]="100F", [24]="150Hz",[25]="200Hz",[27]="250Hz",
  [28]="333F", [29]="500Hz",[30]="D250", [31]="D500", [32]="F500", [33]="F1000",
  [100]="G100",[101]="G150",
}

-- Every string either header pill can ever display. The pill width is measured
-- from the widest of these rather than hard-coded, so the pills are exactly as
-- wide as they need to be on whatever font the radio renders -- and so adding a
-- longer state here can never silently clip it. Keep this list in step with
-- drawHeader.
local PILL_TEXTS = { "NO GPS", "NO FIX", "ACQUIRING", "GPS LOCK", "ARMED",
                     "DISARMED", "BLOCKED" }

-- ---------------------------------------------------------------------------
--  The MODE pill -- the header's third pill, which shows the FC's own
--  flight-mode string. Two small pieces of data.
--
--  MODE_REF sizes it. The pill is a FIXED width, measured once from the widest
--  four-character string any supported firmware can send, so it never resizes
--  and the model name beside it never moves. Four characters is not a house
--  rule, it is what the wire carries: ArduPilot's Mode::name4() writes into a
--  char[5] (AP_Notify.h) and Betaflight and INAV pick from short literals.
--  "MANU" is the widest on both font sets (38 px at 480, 51 px at 800) --
--  Tests/mode_pill_probe.py measures every string of all three firmwares.
local MODE_REF = "MANU"

--  MODE_ALERT: the strings that earn amber. The rule is "the model is flying
--  itself somewhere and you may not have asked" -- every one of these is a
--  return-to-home under some name -- plus "!ERR", which is the FC refusing to
--  arm and announcing it with a '!' of its own.
--
--  This is a mode-name table, and this project has learned to distrust those
--  (see AP_MODES, and the STAB collision it took a second pass to find). It is
--  acceptable HERE, and only here, because it cannot do harm: it feeds a COLOR
--  and nothing else. A missing entry costs a highlight; a wrong entry paints
--  amber where blue belonged. Neither can move an arm edge, a home point or an
--  altitude, which is exactly what a wrong AP_MODES entry did.
--
--  "WAIT" IS NOT HERE, for the reason spelled out at FM_BLOCKED: it reads like
--  a warning and is not one, and amber would paint the pill from power-up to
--  the first take-off. "LAND" and its ArduPilot spellings are not here either
--  -- landing is usually commanded, so amber would cry wolf at the end of every
--  normal flight, and INAV 7.x puts LAND in its DISARMED chain, which would
--  paint a parked model amber. "RTL " needs no entry of its own: ArduPilot's
--  pad byte is trimmed before the lookup.
local MODE_ALERT = {
  ["!ERR"] = true,                        -- INAV, Betaflight 4.3/4.4: arming refused
  RTH  = true,                            -- Betaflight GPS Rescue, INAV return-to-home
  WRTH = true,                            -- INAV, return-to-home from a waypoint run
  RTL  = true, SRTL = true, QRTL = true,  -- ArduPilot: return, smart return, QuadPlane
}

-- ---------------------------------------------------------------------------
--  MODEL NAME, straight from the radio.
--
--  model.getInfo() is an EdgeTX ROTable (linit.c registers `model` in the shared
--  `rotables` table), so unlike `coroutine` it IS reachable from a widget's Lua
--  state. It returns .name -- at most LEN_MODEL_NAME = 15 chars on a color
--  radio (dataconstants.h).
--
--  The name is NOT read here: checkModel() already calls model.getInfo() once a
--  frame to spot a model switch, and leaves the name in mdlName. This used to run
--  its own 5 s poll to avoid the per-call table allocation, but that allocation is
--  now paid anyway -- and sharing it means a rename or a model change reaches the
--  header on the very next frame instead of up to five seconds later.
-- ---------------------------------------------------------------------------
local mdl = { raw = nil, txt = "", w = 0, h = 0, maxW = -1, font = -1 }

-- Shorten to fit, marking the cut with ".." so a clipped name never masquerades
-- as the whole one. Only ever runs when a name is genuinely too long.
local function fitText(s, font, maxW)
  local w, h = textSize(s, font)
  if w <= maxW then return s, w, h end
  local n = #s
  while n > 1 do
    n = n - 1
    local t = string.sub(s, 1, n) .. ".."
    w, h = textSize(t, font)
    if w <= maxW then return t, w, h end
  end
  return "", 0, h
end

local function modelLabel(font, maxW)
  if mdlName ~= mdl.raw then mdl.raw, mdl.maxW = mdlName, -1 end  -- changed: refit
  if mdl.maxW ~= maxW or mdl.font ~= font then               -- layout changed: refit
    mdl.maxW, mdl.font = maxW, font
    mdl.txt, mdl.w, mdl.h = fitText(mdl.raw or "", font, maxW)
  end
  return mdl.txt, mdl.w, mdl.h
end

-- ===========================================================================
--  SCREEN PROFILES
--
--  EVERY number that depends on the size of the screen lives in this table and
--  nowhere else. No layout or drawing code below tests the resolution -- it
--  reads L.P.<field>. That is the whole point: adding a radio is a DATA change,
--  not a code change, so the flight logic cannot be broken by porting the UI.
--
--  To add a resolution:
--    1. copy the nearest profile, set w/h and the name,
--    2. adjust the numbers against a real screenshot of that radio,
--    3. nothing else -- profileFor() picks it up automatically.
--
--  A panel that is not listed here -- exactly, or in a profile's `also` list --
--  is REJECTED, and the widget prints the unsupported-screen notice instead of
--  drawing. This used to fall back to the nearest profile by size, which is
--  wrong for a screen that is nothing like either of them: a 320x240 PA01 would
--  have been handed the 480x272 layout and drawn a third of it off the edge.
--  Refusing is honest; guessing is not.
--
--  The FONT CONSTANTS are per-profile too, because EdgeTX scales its fonts to
--  the panel: the same SMLSIZE is physically much smaller on a 480x272 radio, so
--  a bigger screen can afford a heavier face for the same job.
-- ===========================================================================
-- ---------------------------------------------------------------------------
--  FONT CONSTANTS THAT OLDER FIRMWARE DOES NOT DEFINE.
--
--  EdgeTX only exposed STDSIZE to Lua in 2.11 (api_general.cpp). On 2.8-2.10 the
--  global is nil, and referencing it here blew the widget up on first draw:
--      ERROR in refresh(): attempt to perform arithmetic on field 'fStripV'
--  The standard face has always been flag 0, so resolve it ourselves. BOLD has
--  existed on color radios since at least 2.8, but guard it the same way and
--  fall back to the standard face rather than crash if a build lacks it.
--
--  Everything else GPSQR calls -- getValue, getFieldInfo, getGeneralSettings,
--  model.getInfo, lcd.sizeText, the EVT_* codes, WHITE/BLACK/CENTER/RIGHT --
--  is present in 2.8.0, so that is the floor for this widget.
-- ---------------------------------------------------------------------------
local F_STD  = STDSIZE or 0
local F_BOLD = BOLD or F_STD

local PROFILES = {
  {
    name = "800x480", w = 800, h = 480,   -- RadioMaster TX16S MK3 (verified)
    pad = 10,
    -- fonts
    fLabel = SMLSIZE, fVal = DBLSIZE, fPill = SMLSIZE, fTimer = MIDSIZE,
    fBatt  = MIDSIZE, fStripL = SMLSIZE, fStripV = F_STD,  fCoL  = SMLSIZE,
    fCo    = F_BOLD,  fName = MIDSIZE,
    fPhBig = DBLSIZE, fPhSm = SMLSIZE,
    -- header
    hdrGap = 8, hdrMin = 44, pillH = 30, pillPad = 14,
    battW = 40, battH = 20, battNub = 3, battGap = 8,
    -- stat cards
    accentW = 5, cardPadX = 16, cardPadTop = 8, cardPadRight = 10, cardPadBot = 12,
    -- bottom strip
    stripH = 74, stripPadTop = 10, stripPadBot = 12,
    -- right-hand column
    rcFrac = 0.30, qrFrac = 0.60, qrMargin = 0.07, coordPadX = 10,
    -- QR placeholder text, offsets from the card's center line
    phUp = 30, phDown = 14,
    -- Labels that have to shrink on a narrower panel. Only the ones that differ
    -- are listed; everything else reads the same on every screen.
    lblMaxDist = "MAX DISTANCE TO HOME",
    lblMaxAlt  = "MAX ALTITUDE",
    lblTxPwr   = "TX POWER",
    lblRxBatt  = "RX BATTERY",
    lblMah     = "BATT USED",
    mslSep     = " ",     -- between the MSL figure and its unit: "2427 m MSL"
    -- slack demanded by the "is this legible?" test in computeLayout
    okSlack = 4,
  },
  {
    name = "480x272", w = 480, h = 272,   -- TX16S MK1/MK2, X10, T16, T18, X12S...
    -- Font metrics measured from a real TX16S MK2 (Snapshots/screen-2000-01-01-
    -- 032805): SMLSIZE line height 16 / cap 9, DBLSIZE line height 37 / cap 22 --
    -- roughly 0.69x the MK3's. The card VALUES are MIDSIZE here, not DBLSIZE:
    -- three card rows plus header plus the ELRS strip leave 49 px per row, and a
    -- DBLSIZE value needs 55. That is what made the first MK2 build refuse the
    -- screen and print the setup checklist instead.
    pad = 6,
    -- Header runs one step smaller than the MK3's: the clock and the battery
    -- percentage are the standard face, not MIDSIZE, which levels them with the
    -- model name and hands the freed width to it.
    fLabel = SMLSIZE, fVal = MIDSIZE, fPill = SMLSIZE, fTimer = F_STD,
    -- ELRS values are SMLSIZE here. At the standard face "-128dBm" needs 67 px
    -- and "2000mW" 65 of the cell's 62, so the two extremes of RSSI and TX power
    -- ran into their neighbors. The value row keeps its emphasis through COLOR
    -- (white against the label's gray), not size.
    fBatt  = F_STD,   fStripL = SMLSIZE, fStripV = SMLSIZE,  fCoL  = SMLSIZE,
    -- LAT/LON values are SMLSIZE here, not the standard face: the coordinate card
    -- is only 29 px tall on this panel and stacks two rows 14 px apart, so 12 px
    -- STDSIZE caps leave just 2 px between them. Width agrees -- "-122.084000" in
    -- STDSIZE wants 99 px of the 124 px inner width before the "LON" label.
    fCo    = SMLSIZE, fName = MIDSIZE,
    -- The QR placeholder is MIDSIZE, not DBLSIZE: "NO LOCK" is 130 px in DBLSIZE
    -- and the white card is 126, so it spilled 1 px left and 4 px right onto the
    -- dark panel. MIDSIZE puts it at 98 px, inside the card with room to spare.
    fPhBig = MIDSIZE, fPhSm = SMLSIZE,
    hdrGap = 4, hdrMin = 26, pillH = 20, pillPad = 8,
    battW = 26, battH = 13, battNub = 2, battGap = 6,
    -- The paddings below were MEASURED off a TX16S MK2, not guessed. With the
    -- values inherited from the old untested "small screen" branch the stat-card
    -- label and its value met at exactly the same pixel (zero clearance, visible
    -- on screen as the two touching), and the ELRS strip had 2 px. Clearance is
    --     value ink top - label ink bottom
    --   = (rowH - padBot - LH(value) + DELTA(value)) - (padTop + DELTA + CAP)
    -- and wants to stay >= 3 px. Current: card +4, ELRS +8, placeholder +6.
    accentW = 4, cardPadX = 12, cardPadTop = 4, cardPadRight = 8, cardPadBot = 6,
    stripH = 44, stripPadTop = 4, stripPadBot = 5,
    rcFrac = 0.30, qrFrac = 0.60, qrMargin = 0.07, coordPadX = 8,
    -- Re-centered for the MIDSIZE placeholder: its line box is 8 px shorter than
    -- DBLSIZE's, so the pair would otherwise sit high in the card.
    phUp = 18, phDown = 7,
    -- Shortened for this panel -- measured against a TX16S MK2. At full length
    -- "MAX DISTANCE TO HOME" needs 151 px of the card's 138. Closing the space in
    -- the MSL note buys the 2 px that "32805 ft MSL" was over by in imperial.
    lblMaxDist = "MAX DIST TO HOME",
    lblMaxAlt  = "MAX ALT",
    -- Strip cells are 66.9 px here (468 px of card width / 7), and a label is drawn
    -- CENTERED in one, so it must clear the 1 px divider on each side: budget 64.9.
    -- Figures from label_audit_480.py, which scores against the font model fitted
    -- to a real MK2 and treats anything within 3 px as not fitting:
    --   "TX POWER"    60.0 px   5 px clear   -> fits, so it is spelled out
    --   "RX BATTERY"  69.2 px   over by 4    -> short form
    --   "BATT USED"   66.2 px   over by 1    -> short form
    -- "TX POWER" was abbreviated when the strip stopped short of the right column
    -- with FIVE cells and one was 62 px wide; going full-width and seven cells is
    -- what bought the room. Its alias stays in this table rather than being
    -- deleted -- it is the mechanism for shortening the label again on a narrower
    -- panel, and deleting it would mean re-deriving this the next time.
    lblTxPwr   = "TX POWER",
    lblRxBatt  = "RX BATT",
    -- Over by ONE pixel, which is why the short form is arithmetic rather than
    -- caution -- and why it must not be "restored" on the reasoning that 66.2 fits
    -- a 66.9 px cell. It does not: the dividers take a pixel each. The unit lives
    -- in the value ("850mAh"), which is why neither label repeats it.
    lblMah     = "USED",
    mslSep     = "",
    okSlack = 2,
  },
  {
    name = "480x320", w = 480, h = 320,   -- GX15, PL18/EV/U, ST16, T15/Pro, T22, TX15
    -- ===================================================================
    --  MEASURED ON A RadioMaster TX15 (EdgeTX 2.12.2, PR #2). The other five
    --  radios in this class -- GX15, PL18/EV/U, ST16, T15/Pro, T22 -- are still
    --  untested, and the clearances at the foot of this note are what they are
    --  relying on.
    -- ===================================================================
    -- This profile used to copy 480x272's FONTS outright, on the reasoning that
    -- a face is the one thing that cannot be known without the radio. The TX15
    -- screenshots settled it: the ladder IS the MK2's. Seven strip labels
    -- measured off real TX15 ink match the harness's width model at cap 9 to a
    -- mean 1.56 px -- the same accuracy that model reaches against the MK2 it was
    -- fitted to. So `font_model.ALIAS (480,320) -> (480,272)` is confirmed rather
    -- than assumed, and THAT is what licenses the larger faces below. They were
    -- picked against measured ink (Tests/audit_320.py), not by eye.
    --
    -- This started as the 480x272 profile letterboxed, and the extra height went
    -- wherever the arithmetic dropped it. Two things looked wrong, and both are
    -- fixed by the numbers below rather than by any change to the layout code:
    --
    --   stripH = 50 is SOLVED, not chosen. It is the only value that makes the
    --   coordinate card line up with the HEADING card beside it: rowH becomes 67,
    --   so the QR card (140, clamped by the column width) plus a gap lands the
    --   coordinate card at y=191 -- exactly where the third card row starts -- and
    --   67 px tall, so the two share a bottom edge as well. At 44 it sat 4 px
    --   high, which reads as a mistake precisely because it is so nearly right.
    --
    --   cardPadTop/Bot 7/5 keep the value tucked under its label. The value is
    --   bottom-aligned in the card, so the padding has to answer to the VALUE's
    --   height: 13/11 was fitted around a MIDSIZE value, and left as-is under a
    --   DBLSIZE one it pushed the pair apart again. 7/5 restores the tucked-in
    --   look the TX15 screenshots show.
    --
    -- The ELRS strip's own padding is unchanged -- its value row is still
    -- SMLSIZE, so 7/8 still holds the tested 10 px label-to-value gap in a 50 px
    -- strip. That row stays small ON PURPOSE while everything around it grew:
    -- the cell is 66.9 px and STDSIZE does not fit what it actually holds.
    -- "250mAh" is already 62.3 px, so USED would drop a size within the first
    -- minute of a flight, and TX POWER would change size whenever ELRS dynamic
    -- power crossed 1000 mW -- a row that resizes itself under the pilot, at the
    -- moments the pilot is reading it. One size that always fits beats a bigger
    -- one that sometimes does. 800x480 can afford F_STD there because its cell
    -- is 111 px, not 67.
    --
    -- WHAT IS TIGHT, because a future change has to know where the walls are.
    -- From audit_320.py, which drives the widest string each cell can ever hold:
    --   "123 km/h"  DBLSIZE  134.6 px of a 138 px card       3.4 px clear
    --   "NO LOCK"   DBLSIZE  131.6 px of the 140 px QR card  4.2 px each side
    -- Both sit just outside the width model's own +-3 px band, and they are the
    -- first two things to break if an untested radio here draws wider.
    pad = 6,
    fLabel = SMLSIZE, fVal = DBLSIZE, fPill = SMLSIZE, fTimer = F_STD,
    fBatt  = F_STD,   fStripL = SMLSIZE, fStripV = SMLSIZE,  fCoL  = SMLSIZE,
    fCo    = F_BOLD,  fName = MIDSIZE,
    fPhBig = DBLSIZE, fPhSm = SMLSIZE,
    hdrGap = 4, hdrMin = 26, pillH = 20, pillPad = 8,
    battW = 26, battH = 13, battNub = 2, battGap = 6,
    accentW = 4, cardPadX = 12, cardPadTop = 7, cardPadRight = 8, cardPadBot = 5,
    stripH = 50, stripPadTop = 7, stripPadBot = 8,
    rcFrac = 0.30, qrFrac = 0.60, qrMargin = 0.07, coordPadX = 8,
    phUp = 24, phDown = 18,
    -- Same width, so the same labels have to fit the same card. Keeping them
    -- identical also keeps the two profiles comparable in profile_test.
    lblMaxDist = "MAX DIST TO HOME",
    lblMaxAlt  = "MAX ALT",
    lblTxPwr   = "TX POWER",
    lblRxBatt  = "RX BATT",
    -- Same 66.9 px strip cell as 480x272, drawn at the same size, so the same
    -- arithmetic applies: see the note there. "TX POWER" is the one label spelled
    -- out, on 5 px of clearance; it is still the FIRST label to shorten if one of
    -- the five untested radios in this class turns out to draw wider than the
    -- TX15 did.
    lblMah     = "USED",
    mslSep     = "",
    okSlack = 2,
  },
}

-- Pick a profile from the PANEL size, not the zone: the zone shrinks when the
-- pilot leaves the top bar on, but the fonts do not. Returns nil for a panel no
-- profile claims -- see the note on the PROFILES table about why that is a
-- refusal and not a best guess.
local function profileFor(zw, zh)
  local sw = (LCD_W and LCD_W > 0) and LCD_W or zw
  local sh = (LCD_H and LCD_H > 0) and LCD_H or zh
  for i = 1, #PROFILES do
    local p = PROFILES[i]
    if p.w == sw and p.h == sh then return p end
    local a = p.also
    if a then
      for j = 1, #a do
        if a[j][1] == sw and a[j][2] == sh then return p end
      end
    end
  end
  return nil
end

-- Layout computed from the widget zone plus the profile above. Everything the
-- drawing code needs is derived here, once, and cached on the zone geometry.
local function computeLayout(z)
  local OX, OY, W, H = z.x, z.y, z.w, z.h
  local P   = profileFor(W, H)
  -- No profile claims this panel. Stop here: everything below indexes P, and a
  -- layout built from another radio's numbers would draw off the edge of the
  -- screen. getLayout caches on the same four fields, so they must be present.
  if P == nil then
    return { OX = OX, OY = OY, W = W, H = H, ok = false, badPanel = true }
  end
  local pad = P.pad
  local gap = pad
  local L = { OX = OX, OY = OY, W = W, H = H, P = P, pad = pad, gap = gap }
  -- One font set for both resolutions. EdgeTX already sizes its fonts to the
  -- radio's screen (they are MUCH larger on an 800x480 radio than on 480x272), so
  -- the same constants stay proportionate -- bumping them up over-sized everything.
  L.fLabel = P.fLabel; L.fVal = P.fVal
  L.fPill  = P.fPill;  L.fTimer = P.fTimer; L.fBatt = P.fBatt
  L.fStripL   = P.fStripL
  -- LAT/LON. The label stays SMLSIZE -- the SAME font as every other label on the
  -- screen (fLabel, fStripL), because they all read as one tier and one of them
  -- sitting a size larger looks like a mistake.
  -- The VALUE cannot take a full size step: MIDSIZE needs 238 px of the card's
  -- 214 px of inner width for a worst-case "-180.000000", and the only way to
  -- find that width -- a wider right column -- starves the left column until
  -- "MAX DISTANCE TO HOME" clips (that label still fits at a 0.33 split, MIDSIZE
  -- needs 0.335). So the value takes the BOLD face: same size as STDSIZE, clearly
  -- heavier, 140 px worst case against 176 px free.
  L.fCoL   = P.fCoL;   L.fCo    = P.fCo
  L.fPhSm  = P.fPhSm
  -- Model name. EdgeTX's COLORLCD font ladder (api_general.cpp + fonts.cpp) is
  --   TINSIZE(XXS) < SMLSIZE(XS) < STDSIZE = BOLD(bold STD) < MIDSIZE(L)
  --   < DBLSIZE(XL) < XLSIZE(LXL) < XXLSIZE
  -- There is NOTHING between STD and L, so MIDSIZE is the one real step up -- and
  -- it still leaves room for a full 15-character name (the longest EdgeTX allows,
  -- LEN_MODEL_NAME). Matching the timer makes the header's two text objects read
  -- as a pair.
  -- NB a font is a 4-bit INDEX (FONT_MASK 0x0F00), not a set of flags: BOLD is a
  -- font of its own, so it must never be ADDED to a size -- MIDSIZE + BOLD would
  -- silently become DBLSIZE.
  L.fName  = P.fName
  L.fStripV   = P.fStripV
  L.fPhBig = P.fPhBig
  -- Header height. FLIGHT TIME now sits BESIDE the timer on one line, so this no
  -- longer has to fit them stacked -- but the formula is deliberately unchanged:
  -- the extra room becomes comfortable padding around the pills, and it holds the
  -- card grid below at exactly the size it has always had. Font line heights vary
  -- a lot between radios, hence measuring rather than hard-coding.
  -- The GPS and ARM pills share ONE width -- the pair reads as a unit, and the
  -- arm pill's position must not shift when the GPS pill's text changes. That
  -- width is the widest state string plus a symmetric margin, so it is the
  -- minimum that can hold every state without clipping. The MODE pill gets its
  -- own, narrower width just below, for the same reason applied to a different
  -- set of strings. All of them are measured once (the layout is cached), never
  -- per frame.
  L.pillH = P.pillH
  local pw = 0
  for i = 1, #PILL_TEXTS do
    local w = textSize(PILL_TEXTS[i], L.fPill)
    if w > pw then pw = w end
  end
  L.pillW = pw + 2 * P.pillPad
  -- The MODE pill gets its OWN fixed width, narrower than the pair above because
  -- it only ever holds four characters. Sized from MODE_REF, never from the
  -- string currently showing: a pill that resized with its text would shove the
  -- model name every time the mode changed, and the widest string is "FAILSAFE"-
  -- class traffic, i.e. the moment the header must not redraw itself. Measured
  -- once here, like everything else in this function.
  L.modeW = textSize(MODE_REF, L.fPill) + 2 * P.pillPad

  -- L.fLabel, not a literal SMLSIZE: the header's height must be measured with
  -- the same font the labels below it are drawn in, and that is a PROFILE field.
  -- The two agree on all three panels today, so this is insurance -- against a
  -- new profile choosing a different label font and silently sizing the header
  -- from the old one.
  local _, lblH   = textSize("Ag", L.fLabel)
  local _, timerH = textSize("00:00", L.fTimer)
  local headerH = lblH + timerH + P.hdrGap
  local hmin = P.hdrMin
  if headerH < hmin then headerH = hmin end
  L.header = { OX, OY, W, headerH }
  local cTop  = OY + headerH + gap
  local cH    = H - headerH - gap - pad
  local cW    = W - 2 * pad
  local cLeft = OX + pad
  local rcW   = floor(cW * P.rcFrac)
  local leftW = cW - rcW - gap
  local rightX = cLeft + leftW + gap
  -- left: 3x2 stat cards + ELRS strip
  local stripH  = P.stripH
  local cardsH = cH - stripH - gap
  local rowH   = floor((cardsH - 2 * gap) / 3)
  local colW   = floor((leftW - gap) / 2)
  L.cards = {}
  for r = 0, 2 do
    for c = 0, 1 do
      L.cards[#L.cards + 1] = { cLeft + c * (colW + gap), cTop + r * (rowH + gap), colW, rowH }
    end
  end
  -- The bottom strip runs the FULL width of the screen, not just the stat-card
  -- column. It used to stop short so two buttons could sit beside it (QR RATE,
  -- UNITS); both are gone -- the QR rate is fixed at the only value worth having
  -- and UNITS is a constant at the top of the file -- so the row is now one
  -- uninterrupted band of readouts. Seven cells across the whole width are
  -- WIDER than the old five across the card column (66.9 px vs 62.4 at 480x272,
  -- 111.4 vs 105.2 at 800x480), so every cell gained room in the process.
  L.strip = { cLeft, cTop + cardsH + gap, cW, stripH }
  -- right column: QR card, coordinates
  -- The white canvas spans the FULL column width, so its left and right edges
  -- line up with the coordinate card directly below it. Only its HEIGHT is the
  -- square code's size -- the code itself stays square and is centered in the
  -- canvas. Making the canvas square instead would inset it by a few pixels on
  -- either side (4 on 480x272, 1 on 800x480) and the two cards would not agree.
  -- The canvas cannot simply be made rcW TALL as well: that would eat the
  -- coordinate card's height, and on 480x272 it has only 33 px to give.
  local qrCard = min(rcW, floor(cH * P.qrFrac))
  L.qr = { rightX, cTop, rcW, qrCard }
  local margin = floor(qrCard * P.qrMargin)
  -- QSIZE, not a literal 29: the module count is a property of the QR VERSION,
  -- and a layout that hard-codes it would silently mis-size the code the day the
  -- payload outgrows version 3.
  L.qms = floor((qrCard - 2 * margin) / QSIZE)
  if L.qms < 2 then L.qms = 2 end
  L.qrX = rightX + floor((rcW - L.qms * QSIZE) / 2)
  L.qrY = cTop + floor((qrCard - L.qms * QSIZE) / 2)
  L.rcx = rightX + floor(rcW / 2)
  local by = L.strip[2]
  -- The coordinate card starts directly under the QR: there is no "SCAN FOR MAPS"
  -- caption any more (a QR code does not need to announce itself), and the ~20 px
  -- that freed up goes into this card so LAT/LON can be read at a glance.
  local coordY = cTop + qrCard + gap
  L.coord = { rightX, coordY, rcW, by - gap - coordY }

  -- ---------------------------------------------------------------------------
  -- Is this zone actually big enough to lay the instrument out LEGIBLY?
  --
  -- A zone can easily be wide enough yet far too short: leaving the top bar,
  -- flight mode, sliders or trims switched on for the screen costs over 120 px of
  -- height, and EdgeTX simply hands the widget the smaller rectangle without
  -- saying so. Nothing errors -- the cards just squeeze until statCard draws the
  -- value ABOVE its own label and the coordinate card computes to a NEGATIVE
  -- height, which is unreadable rather than merely cramped.
  --
  -- So check the two dimensions that collapse first, derived from the radio's own
  -- font metrics rather than hard-coded pixels:
  --   * a stat card must fit its value's line box, a label line, and a little
  --     slack -- below that the two overlap (measured: they touch at rowH 82 with
  --     the 800x480 fonts, where a properly configured screen gives 94).
  --   * the coordinate card stacks TWO rows at half its height each, so its rows
  --     sit coord_h/2 apart; they need to clear a line box between them. One
  --     line box of total height is NOT enough (measured: at 28 px the LAT and
  --     LON values print through each other).
  local _, lhLbl = textSize("Ag", L.fLabel)
  local _, lhVal = textSize("0", L.fVal)
  local _, lhCo  = textSize("0", L.fCo)

  -- ...and the label row's WIDTH, which none of the height tests above can see.
  -- A card label is not optional, so if the longest one cannot fit the card this
  -- profile does not suit the radio and the checklist is the honest answer.
  -- (The MSL note shares that row but is handled at draw time -- see statCard.)
  --
  -- This matters most on a profile running letterboxed on a panel nobody has
  -- tested: the extra height satisfies every check above, so without this a radio
  -- with larger fonts would draw labels straight through their neighbors rather
  -- than refuse. Measured on 480x320: the collision starts at 1.20x the 480x272
  -- metrics, and nothing else complained.
  L.labelRoom = colW - P.cardPadX - P.cardPadRight

  L.ok = (rowH >= lhVal + lhLbl + P.okSlack)
         and (L.coord[4] >= lhCo + floor(lhCo / 3))
         and (cardsH > 0) and (leftW > 0) and (rcW > 0)
         and (L.labelRoom >= textSize(P.lblMaxDist, L.fLabel))
  return L
end

-- The layout depends on NOTHING but the zone geometry, and that only changes if
-- the pilot edits the screen, so build it once and reuse it. It is ~15 tables
-- and a couple of lcd.sizeText calls -- cheap once, but it used to run on every
-- every frame -- ~11-13 a second, measured -- straight into the garbage collector.
local function getLayout(z)
  local L = st.L
  if L and L.OX == z.x and L.OY == z.y and L.W == z.w and L.H == z.h then return L end
  return computeLayout(z)
end

-- ---------------------------------------------------------------------------
--  "zone too small" screen.
--
--  EdgeTX draws NOTHING in a widget's zone -- every pixel here is ours, title
--  included -- so this doubles as the setup recipe, which is exactly the moment
--  you need it. Lines are drawn most-important-first and only while they fit, so
--  a tiny zone degrades to just the headline instead of overprinting.
--
--  (The old version hard-coded +/-16 px offsets around the center. DBLSIZE has a
--  55 px line box, so the title's glyphs ran straight through the hint below it.)
-- ---------------------------------------------------------------------------
local SMALL_HINT = {
  "needs a FULL-SCREEN zone",
  "in Screens setup:",
  "Layout: one big zone",
  "Top bar: OFF",
  "Flight mode: OFF",
  "Sliders: OFF",
  "Trims: OFF",
}

-- Shown when the RADIO's panel is one GPSQR has no profile for. Nothing the
-- pilot can change in Screens setup will help, so say that instead of printing
-- a checklist they would work through for nothing.
local PANEL_HINT = {
  "unsupported screen size",
  "supported panels:",
  "800x480",
  "480x272",
  "480x320",
}

local function drawTooSmall(z, badPanel)
  local HINT = badPanel and PANEL_HINT or SMALL_HINT
  lcd.drawFilledRectangle(z.x, z.y, z.w, z.h, C.bg)
  local pad  = 6
  local cx   = z.x + floor(z.w / 2)
  local maxW = z.w - 2 * pad

  -- Title steps down the font ladder until it fits the width of the zone.
  local tf, tw, th = DBLSIZE, 0, 0
  tw, th = textSize("GPSQR", tf)
  if tw > maxW then tf = MIDSIZE; tw, th = textSize("GPSQR", tf) end
  if tw > maxW then tf = 0;       tw, th = textSize("GPSQR", tf) end
  if tw > maxW then tf = SMLSIZE; tw, th = textSize("GPSQR", tf) end

  -- textSize returns the LINE box height, so stacking by it cannot overlap.
  local _, lh = textSize("Ag", SMLSIZE)
  local tgap  = floor(lh / 3)

  local n = floor((z.h - 2 * pad - th - tgap) / lh)
  if n < 0 then n = 0 elseif n > #HINT then n = #HINT end

  local y = z.y + floor((z.h - (th + tgap + n * lh)) / 2)
  if y < z.y + pad then y = z.y + pad end
  lcd.drawText(cx, y, "GPSQR", tf + C.text + CENTER)
  y = y + th + tgap
  for i = 1, n do
    local col = (i == 1) and C.amber or ((i == 2) and C.label or C.dim)
    lcd.drawText(cx, y, HINT[i], SMLSIZE + col + CENTER)
    y = y + lh
  end
end

local function pill(x, y, w, h, col, txt, font)
  lcd.drawFilledRectangle(x, y, w, h, col)
  local _, ph = textSize(txt, font)
  lcd.drawText(x + floor(w / 2), y + floor((h - ph) / 2), txt, font + BLACK + CENTER)
end

-- Header, laid out as FOUR objects evenly spaced across the bar:
--
--   [model name]   [GPS pill][ARM pill][MODE pill]   [timer]   [battery]
--
-- The pills count as ONE object: they keep a fixed gap so the group reads as a
-- unit and no pill drifts when its neighbor's text changes -- which is why all
-- three have a width fixed at layout time rather than one that follows the
-- string. Only the space BETWEEN objects is distributed, and it is split equally.
-- The name is pinned to the left margin and the battery to the right, exactly
-- where they have always sat. The MODE pill is absent on a model with no FM
-- sensor, and the name simply gets that room back.
--
-- The timer needs no label: mm:ss beside an arm-state pill is unambiguous, and
-- dropping "FLIGHT TIME" is what buys the room for the model name.
local function drawHeader(L)
  local OX, OY, W = L.OX, L.OY, L.W
  local hh = L.header[4]
  lcd.drawFilledRectangle(OX, OY, W, hh, C.header)
  local cy = OY + floor(hh / 2)
  local pad, gap = L.pad, L.gap

  -- ---- battery: geometry first (it anchors the right edge), drawn further down
  local iw   = L.P.battW
  local ih   = L.P.battH
  local nub  = L.P.battNub
  local pgap = L.P.battGap
  local pct = st.battPct
  local btxt = (pct ~= nil) and string.format("%d%%", floor(pct + 0.5)) or "--"
  local battW, bph = textSize(btxt, L.fBatt)
  local battBlockW = battW + pgap + iw + nub

  -- ---- object widths
  local pillH, pillW = L.pillH, L.pillW
  -- The MODE pill is present only when the model HAS an FM sensor, which is a
  -- static property of the model -- so the header does not reflow in flight. It
  -- is reserved here, before the name is measured, because the name is the one
  -- elastic object and must be told the truth about how much room is left.
  local showMode = (st.modeTxt ~= nil)
  local pillsW = pillW * 2 + gap
  if showMode then pillsW = pillsW + gap + L.modeW end
  local tstr = fmtTime(st.flightSec)
  local timerW, tmh = textSize(tstr, L.fTimer)
  -- Reserve at least "00:00" so the spacing does not twitch as the digits change,
  -- but let a >99 minute flight widen the slot rather than overflow it.
  local refW = textSize("00:00", L.fTimer)
  if refW > timerW then timerW = refW end

  -- The name is the only elastic object: it gets whatever is left once the fixed
  -- objects and a minimum gap each have been reserved, and is trimmed to fit.
  local avail   = W - 2 * pad
  local nameMax = avail - pillsW - timerW - battBlockW - 3 * gap
  local nameTxt, nameW, nameH = modelLabel(L.fName, nameMax)

  local slots = (nameW > 0) and 4 or 3
  local g = floor((avail - nameW - pillsW - timerW - battBlockW) / (slots - 1))
  if g < gap then g = gap end

  -- ---- draw left to right
  local x = OX + pad
  if nameW > 0 then
    lcd.drawText(x, cy - floor(nameH / 2), nameTxt, L.fName + C.text)
    x = x + nameW + g
  end

  -- "NO GPS" is a claim about the MODEL, so only make it when the model really has
  -- no GPS sensor. With one fitted but no position yet the honest word is NO FIX:
  -- the GPS exists, it simply has not found itself. Telling a pilot who knows his
  -- quad carries a GPS that there is none reads as a fault rather than a wait.
  local fc, ft
  if not st.hasFix then fc, ft = C.red, st.gpsKnown and "NO FIX" or "NO GPS"
  elseif not st.satsOk then fc, ft = C.amber, "ACQUIRING"
  else fc, ft = C.green, "GPS LOCK" end
  local pillY = cy - floor(pillH / 2)
  pill(x, pillY, pillW, pillH, fc, ft, L.fPill)
  -- The model's arm state, in THREE words. Amber never means one thing on its
  -- own -- the word says whose complaint it is, which is the whole point of
  -- BLOCKED existing (see the armBlocked/armWarn note in updateLogic):
  --    ARMED    green   armed, all well
  --    ARMED    amber   armed, IN FAILSAFE
  --    DISARMED gray    disarmed, ready to arm, nothing to report
  --    DISARMED amber   OUR warning: no GPS lock yet, so arming now would cost
  --                     the home point. Something to WAIT for.
  --    BLOCKED  amber   the FC's own refusal (isArmingDisabled): throttle up,
  --                     calibration pending, arm switch on at boot. Something to
  --                     go and FIX. Always amber -- it is only ever set with warn.
  -- (Home capture happens in the background; it is not worth nagging about.)
  local at
  if st.armed then at = "ARMED"
  elseif st.armBlocked then at = "BLOCKED"     -- the FC's refusal, not ours
  else at = "DISARMED" end
  local ac
  if st.armWarn then ac = C.amber
  else ac = st.armed and C.green or C.dim end
  pill(x + pillW + gap, pillY, pillW, pillH, ac, at, L.fPill)

  -- THIRD PILL: the flight-mode string, straight off the FC.
  --
  -- The color says what the STRING says and nothing else. That is the division
  -- of labor between this pill and the one before it: the ARM pill NORMALIZES
  -- the arm state across three firmwares, this one does not translate at all. So
  -- a Betaflight master model refusing to arm reads "BLOCKED | ACRO" -- its
  -- refusal rides in the marker -- while INAV reads "BLOCKED | !ERR", its refusal
  -- being in the name. Both are true, and the ARM pill is the one that reads the
  -- same everywhere.
  --
  --    !FS!    red     the FC has declared failsafe
  --    !ERR    amber   the FC refuses to arm, and prefixes '!' to say so
  --    RTH/RTL amber   the model is flying itself home; you may not have asked
  --    (other) blue    a fact, not a verdict
  --    (other) gray    ...and the link is down, so that fact is last-known
  --
  -- BLUE, NOT GREEN, is the resting color on purpose. Green in this widget means
  -- "a good thing is true" -- GPS LOCK, ARMED. A flight mode is neither good nor
  -- bad, and the widget has no basis to say otherwise, so the pill sits OFF the
  -- red/amber/green ladder while it is merely reporting. Stepping onto the ladder
  -- is then itself the signal.
  --
  -- GRAY REPLACES BLUE ONLY. Every model-sourced reading on this screen grays
  -- when the link drops, and a stale mode string should say so -- but graying a
  -- red "!FS!" would hide the most important thing on the screen at the one
  -- moment it matters. Blue is the only state with no severity to lose, so it is
  -- the only one that gives way. (The two pills before this one never gray at
  -- all: their color IS their meaning. That is deliberate, not an oversight.)
  if showMode then
    local mc
    if st.modeTxt == "!FS!" then mc = C.red
    elseif MODE_ALERT[st.modeTxt] then mc = C.amber
    elseif st.stale then mc = C.dim
    else mc = C.blue end
    pill(x + 2 * (pillW + gap), pillY, L.modeW, pillH, mc, st.modeTxt, L.fPill)
  end
  x = x + pillsW + g

  lcd.drawText(x, cy - floor(tmh / 2), tstr, L.fTimer + C.white)

  -- ---- battery, pinned to the right margin
  local bx = OX + W - pad - nub - iw
  local by = cy - floor(ih / 2)
  lcd.drawRectangle(bx, by, iw, ih, C.dim)
  lcd.drawFilledRectangle(bx + iw, cy - 2, nub, 5, C.dim)
  local bcol = C.dim
  if pct ~= nil then
    bcol = (pct > 50) and C.green or ((pct >= 20) and C.amber or C.red)
    local fw = floor((iw - 4) * pct / 100 + 0.5)
    if fw > 0 then lcd.drawFilledRectangle(bx + 2, by + 2, fw, ih - 4, bcol) end
  end
  lcd.drawText(bx - pgap, cy - floor(bph / 2), btxt, L.fBatt + bcol + RIGHT)
end

-- `note` is an optional secondary readout, right-aligned on the LABEL row where
-- there is plenty of unused width. Putting it there keeps the big value at full
-- size -- appending it to the value line overflows the card on real numbers.
local function statCard(rect, accent, label, value, unit, L, note, vcol)
  local x, y, w, h = rect[1], rect[2], rect[3], rect[4]
  lcd.drawFilledRectangle(x, y, w, h, C.card)
  lcd.drawFilledRectangle(x, y, L.P.accentW, h, accent)
  local px = L.P.cardPadX
  local ly = y + L.P.cardPadTop
  lcd.drawText(x + px, ly, label, L.fLabel + C.label)
  if note then
    -- The note shares the label's row, right-aligned. It is SUPPLEMENTARY (the
    -- absolute MSL beside a height above take-off), so when it will not fit
    -- beside the label it is dropped rather than printed through it. Two cases
    -- reach this: a five-digit imperial reading ("32805 ft MSL" clears the
    -- 480x272 card by 5 px, and a taller font eats that), and a radio whose
    -- fonts are bigger than the profile was measured against -- which is exactly
    -- the unknown on any panel running a profile letterboxed.
    if textSize(label, L.fLabel) + textSize(note, L.fLabel) + 4 <= L.labelRoom then
      -- the note is model-sourced too, so it goes stale with the value
      local ncol = (vcol == C.stale) and C.stale or C.dim
      lcd.drawText(x + w - L.P.cardPadRight, ly, note, L.fLabel + ncol + RIGHT)
    end
  end
  -- value and unit are one string: same size, bottom-aligned by construction
  local t = value
  if unit and unit ~= "" then t = value .. " " .. unit end
  local _, vh = textSize(t, L.fVal)
  lcd.drawText(x + px, y + h - L.P.cardPadBot - vh, t, L.fVal + (vcol or C.text))
end

local function drawQR(L)
  local runs = st.qrRuns
  if not runs then return end
  local ms, ox, oy = L.qms, L.qrX, L.qrY
  for i = 1, #runs do
    local r = runs[i]
    lcd.drawFilledRectangle(ox + r[1] * ms, oy + r[2] * ms, r[3] * ms, ms, BLACK)
  end
end

local function drawStrip(L)
  local x, y, w, h = L.strip[1], L.strip[2], L.strip[3], L.strip[4]
  lcd.drawFilledRectangle(x, y, w, h, C.card2)
  lcd.drawFilledRectangle(x, y, w, 3, C.blue)
  -- Seven cells: five link statistics, then two that are not. Each row is
  --    { label, value, unit, goes-gray-on-link-loss }
  --
  -- LINK stays white because 0% IS the answer -- a live reading of a dead link.
  -- The other four link cells all ride inside the link-statistics frame, so once
  -- that stops arriving they are last-known values, including TX POWER and MODE.
  -- Those two look like transmitter-side settings that ought to stay true, and
  -- that is how they used to be drawn -- but ELRS dynamic power moves the
  -- transmitter behind our back: on a real link loss the TX went from 10 mW to
  -- 1000 mW while the widget still confidently displayed 10 mW.
  --
  -- The last two are the reason this is no longer "the ELRS strip": mAh drawn is
  -- model-sourced (so it holds and grays like the rest), and the clock is the
  -- radio's own (so it never grays and can never read "--").
  local items = {
    { "LINK", st.lq   and string.format("%d", st.lq)   or "--", "%",   false },
    { "RSSI", st.rssi and string.format("%d", st.rssi) or "--", "dBm", true  },
    { L.P.lblTxPwr, st.pwr and string.format("%d", st.pwr) or "--", "mW", true },
    { "RATE", st.rfMode and (RF_MODE[st.rfMode] or ("#" .. st.rfMode)) or "--", "", true },
    { L.P.lblRxBatt, st.rxbt and string.format("%.1f", st.rxbt) or "--", "V", true },
    { L.P.lblMah, fmtMah(st.mah), "", true },
    -- The radio's own clock. The only cell here that owes nothing to telemetry,
    -- so it never grays and never reads "--".
    { "CLOCK", clockHM(), "", false },
  }
  local n = #items
  local cw = w / n
  -- Cell dividers are inset from the strip's edges by a FIXED amount rather than
  -- a proportional one: they are a hairline separator, not a border, and 8 px
  -- reads the same on a 44 px strip as on a 74 px one.
  local divInset = 8
  local lblY = y + L.P.stripPadTop
  local _, vh = textSize("0", L.fStripV)
  local valY = y + h - L.P.stripPadBot - vh
  for i = 1, n do
    local cx = x + (i - 1) * cw
    if i > 1 then
      lcd.drawFilledRectangle(cx, y + divInset, 1, h - 2 * divInset, C.card)
    end
    lcd.drawText(cx + floor(cw / 2), lblY, items[i][1], L.fStripL + C.label + CENTER)
    local vtxt = items[i][2]
    if items[i][3] ~= "" and vtxt ~= "--" then vtxt = vtxt .. items[i][3] end
    -- A "--" grays along with everything else. It used to be left white on the
    -- reasoning that gray means "a held value that is no longer live", and a dash
    -- holds nothing -- but the stat cards gray their dashes, so the two halves of
    -- the screen disagreed and the strip lit up white the moment the link died.
    -- One rule instead: while the link is down, everything that depends on it is
    -- gray. LINK is unaffected -- its stale flag is false, because 0% IS live.
    local vc = (st.stale and items[i][4]) and C.stale or C.text
    lcd.drawText(cx + floor(cw / 2), valY, vtxt, L.fStripV + vc + CENTER)
  end
end

local function drawScreen(L)
  lcd.clear()
  lcd.drawFilledRectangle(L.OX, L.OY, L.W, L.H, C.bg)
  drawHeader(L)

  -- Presentation states, so a number is only ever shown when it means something:
  --   no GPS LOCK    every flight figure is "--"  (nothing is trustworthy yet)
  --   locked, on the ground, nothing flown yet
  --                  resting values: 0 distance / 0 altitude / 0 speed,
  --                  heading "--" (meaningless while stationary)
  --   armed          everything live, measured from the take-off point
  --   LANDED after a flight
  --                  the cards switch to that flight's MAXIMA (relabeled
  --                  "MAX ..."), because that is the debrief you want after
  --                  landing. TRIP and FLIGHT TIME already hold their totals.
  local lock = gpsLock()
  local showMax = lock and st.flown and not st.armed

  -- Color for a value that is supposed to be LIVE. When the link is down it is
  -- really a frozen last-known reading, so gray it out. The MAX cards are
  -- deliberately excluded: those are a historical record by design, not stale.
  local live = (st.stale and not showMax) and C.stale or nil

  local dV, dU = "--", ""
  if showMax then dV, dU = fmtDist(st.maxDist)
  elseif lock then dV, dU = fmtDist(st.homeSet and (st.distHome or 0) or 0) end
  -- The card gives the label 237 px (L.labelRoom: colW 263 - padX 16 - padRight
  -- 10). "MAX DISTANCE TO HOME" measures 230 px with a 6% safety margin applied
  -- (~217 px raw), so it fits on SEVEN pixels of slack -- it is the longest label
  -- on the screen, so re-measure before making it any longer.
  -- ("MAX DISTANCE FROM HOME" needs 258 px and would be clipped.)
  -- L.ok now checks this width itself, so a radio whose fonts are bigger than the
  -- profile assumes refuses the screen instead of clipping. The figures still
  -- matter: the check is the backstop, not the design.
  statCard(L.cards[1], C.purple, showMax and L.P.lblMaxDist or "DISTANCE TO HOME",
           dV, dU, L, nil, live)

  -- TRIP is integrated from consecutive GPS fixes, so it may only show a number
  -- once there has been a fix to integrate. It used to key off st.flown alone,
  -- which is set by ARMING -- so a model with no GPS at all turned "--" into a
  -- confident "0 m" the moment it armed, the one flight figure on the screen
  -- claiming a measurement it had no way to make.
  --
  -- The gate is st.tripKnown ("this flight held a lock at some point"), NOT the
  -- current lock: a total that WAS measured is a finished record like the MAX
  -- cards, so losing satellites afterwards must not erase it. On the ground before
  -- take-off there is no total yet, so a current lock is all that 0 requires.
  local tV, tU = "--", ""
  if st.flown then
    if st.tripKnown then tV, tU = fmtDist(st.trip) end   -- held after landing
  elseif lock then tV, tU = fmtDist(0) end
  statCard(L.cards[2], C.teal, "TRIP", tV, tU, L, nil, live)

  -- ALTITUDE: big = height above the take-off point, small = absolute MSL.
  -- The big number only means something once flying, so on the ground it reads 0;
  -- the MSL figure however is live from GPS LOCK onwards, ground included.
  -- After a flight the card shows that flight's maxima -- BOTH of them: the
  -- highest point above take-off and the height above sea level up there. Two
  -- historical figures belong together on a debrief, which is why this note is not
  -- the live one; pairing a maximum with a live reading is what would read oddly.
  -- The label shortens per profile to make room ("MAX ALT" on the 480 panels,
  -- where "MAX ALTITUDE" plus a four-digit note needs 168 px of a 138 px row).
  local aV, aU, aNote = "--", "", nil
  if showMax then
    aV, aU = fmtAlt(st.maxAlt)
    if st.maxMsl ~= nil then
      local mV, mU = fmtMsl(st.maxMsl)
      aNote = mV .. L.P.mslSep .. mU .. " MSL"
    end
  elseif lock then
    local showMsl = st.altMsl ~= nil
    if not st.armed then
      aV, aU = fmtAlt(0)                 -- on the ground: no height above take-off
    elseif st.altRel ~= nil then
      aV, aU = fmtAlt(st.altRel)
    elseif showMsl then
      aV, aU = fmtMsl(st.altMsl)         -- no reference: the big number IS the MSL
      aNote, showMsl = "MSL", false      -- ...so label it rather than repeat it
    end
    if showMsl then
      local mV, mU = fmtMsl(st.altMsl)
      aNote = mV .. L.P.mslSep .. mU .. " MSL"
    end
  end
  statCard(L.cards[3], C.blue, showMax and L.P.lblMaxAlt or "ALTITUDE",
           aV, aU, L, aNote, live)

  local sV, sU = "--", ""
  if showMax then sV, sU = fmtSpeed(st.maxSpeed)
  elseif lock then sV, sU = fmtSpeed(st.armed and st.spdKmh or 0) end
  statCard(L.cards[4], C.amber, showMax and "MAX SPEED" or "SPEED", sV, sU, L, nil, live)

  -- With no satellite sensor the count is unknown, so show "--" rather than a
  -- misleading 0; the accent still reflects whether we have a usable fix.
  -- This one is NOT gated on lock -- it is what you watch while acquiring.
  local satAcc = st.hasFix and (st.satsOk and C.green or C.amber) or C.red
  statCard(L.cards[5], satAcc, "SATELLITES",
           st.satsKnown and tostring(st.sats) or "--", "", L,
           nil, st.stale and C.stale or nil)

  local hV, hU = "--", ""
  -- Prefer the course WE worked out from consecutive fixes; fall back to the
  -- sensor until the model has moved far enough for there to be one. Round
  -- INSIDE the circle: 359.9 must read 0, not 360 -- compassDeg returns
  -- 0..359.99 and rounding the top of that range would wrap past it.
  if lock and st.armed then
    local h = compassDeg(st.cog or st.hdg)
    hV, hU = string.format("%d", floor(h + 0.5) % 360), "deg"
  end
  statCard(L.cards[6], C.orange, "HEADING", hV, hU, L, nil, live)

  drawStrip(L)

  -- right column: QR canvas, then the coordinates under it
  -- the canvas is column-WIDE and code-TALL, so w and h are read separately
  local qx, qy, qcw, qch = L.qr[1], L.qr[2], L.qr[3], L.qr[4]
  lcd.drawFilledRectangle(qx, qy, qcw, qch, C.white)
  local showing = st.qrRuns ~= nil
  if showing then
    drawQR(L)
  else
    local darkc, dimc = lcd.RGB(70, 78, 90), lcd.RGB(120, 130, 145)
    local cy = qy + floor(qch / 2)
    if not st.hasFix then
      -- Two different situations, and the difference is the one thing you want to
      -- know while standing in a field: is this a wait, or is it never coming?
      -- Sensor existence tells them apart, so both lines say which one it is --
      -- and the big word matches the header pill, because a card reading NO GPS
      -- beside a pill reading NO FIX would just look broken.
      lcd.drawText(L.rcx, cy - L.P.phUp,
                   st.gpsKnown and "NO FIX" or "NO GPS", L.fPhBig + darkc + CENTER)
      lcd.drawText(L.rcx, cy + L.P.phDown,
                   st.gpsKnown and "waiting for satellites" or "no GPS sensor",
                   L.fPhSm + dimc + CENTER)
    elseif not st.satsOk then
      lcd.drawText(L.rcx, cy - L.P.phUp, "NO LOCK", L.fPhBig + darkc + CENTER)
      lcd.drawText(L.rcx, cy + L.P.phDown,
                   "need " .. CFG.MIN_SATS .. " satellites", L.fPhSm + dimc + CENTER)
    end
    -- While the first build is running the card is deliberately left CLEAN: it
    -- lasts ~1 s, so a flashed "building" message reads as a glitch. Rebuilds
    -- keep the previous code on screen and never reach this branch at all.
  end

  -- LAT/LON is a SENSOR READOUT: it shows the newest fix, every time one lands.
  -- It used to mirror the coordinates baked into the QR instead, so the two could
  -- never disagree -- but that made a live sensor lag behind itself for a reason
  -- that has nothing to do with it. The QR keeps its own
  -- refresh rate (re-encoding is expensive; see QR_SLICE), so between rebuilds
  -- the card can legitimately be ahead of the code beside it.
  --
  -- Still gated on GPS LOCK, same as the QR: below MIN_SATS a fix can be
  -- kilometers out, and a 6-decimal readout would imply a precision it does not
  -- have. On telemetry loss readSensors HOLDS the last position rather than
  -- reading zeros, so this keeps showing it -- grayed, because it is no longer
  -- live -- which is exactly what you need to walk to a downed model.
  local clat = lock and st.lat or nil
  local clon = lock and st.lon or nil
  local ccx, cyr, ccw, cch = L.coord[1], L.coord[2], L.coord[3], L.coord[4]
  lcd.drawFilledRectangle(ccx, cyr, ccw, cch, C.card)
  local cpx = L.P.coordPadX
  local half = floor(cch / 2)
  local _, clh = textSize("LAT", L.fCoL)
  local _, cvh = textSize("0", L.fCo)
  -- The two rows sit a quarter and three quarters down the card, which reads
  -- correctly while the card is roughly two line boxes tall -- it is on every
  -- panel that has been measured (800x480: 61 px for 2x28; 480x272: 33 for
  -- 2x16). A profile running LETTERBOXED is handed a card it was never drawn
  -- for: 480x320 gives this one 73 px, and proportional spacing would fling LAT
  -- and LON to opposite ends of it with a hole in between. Past 2.5 line boxes,
  -- stop scaling and just center the pair. Below that -- i.e. on both panels
  -- anyone has actually run -- this changes nothing.
  local span = max(clh, cvh)
  if cch > 2 * span + floor(span / 2) then
    half = span
    cyr = cyr + floor((cch - 2 * span) / 2)
  end
  local r1 = cyr + floor(half / 2)
  local r2 = cyr + half + floor(half / 2)
  -- With the link down these are the last position the model reported, so gray
  -- them: still the most useful thing on screen, but no longer live.
  local ccol = st.stale and C.stale or C.text
  local cvx = ccx + ccw - cpx                     -- right edge the values align to
  lcd.drawText(ccx + cpx, r1 - floor(clh / 2), "LAT", L.fCoL + C.label)
  lcd.drawText(cvx, r1 - floor(cvh / 2), clat and coordDisp(clat) or "--",
               L.fCo + ccol + RIGHT)
  lcd.drawText(ccx + cpx, r2 - floor(clh / 2), "LON", L.fCoL + C.label)
  lcd.drawText(cvx, r2 - floor(cvh / 2), clon and coordDisp(clon) or "--",
               L.fCo + ccol + RIGHT)
end

-- ===========================================================================
--  events
-- ===========================================================================
-- No manual reset action: arming zeroes the flight stats AND re-captures home, so
-- there is nothing left for the pilot to reset by hand.

-- THERE ARE NO CONTROLS. Every setting worth having is a constant at the top of
-- the file, and everything else the widget decides for itself: home is captured
-- at take-off, the flight resets on the next arm, the QR rebuilds itself when
-- the model moves. The screen is an instrument, not a menu -- nothing here to
-- press, and nothing to press it by accident.
--
-- (Two buttons used to live under the coordinates: QR RATE and UNITS. There is
-- no rate to set any more -- the code rebuilds on movement, see CFG.QR_MIN_MOVE
-- -- and UNITS is a preference you set once, so it moved to CFG. The row they
-- occupied went to the bottom strip, which is why it runs the full screen width.)

-- ===========================================================================
--  widget entry points  (EdgeTX color-radio widget: WIDGETS/GPSQR/main.lua)
-- ===========================================================================
local inited = false
local function widgetInit()
  buildColors()
  -- use the radio's configured battery range if available, else the CFG fallback.
  -- Stored in battRange so it survives a model change (see checkModel), then
  -- mirrored into the current state.
  battRange.min, battRange.max = CFG.BATT_MIN, CFG.BATT_MAX
  if getGeneralSettings then
    local gs = getGeneralSettings()
    if gs and type(gs.battMin) == "number" and type(gs.battMax) == "number"
       and gs.battMax > gs.battMin then
      battRange.min, battRange.max = gs.battMin, gs.battMax
    end
  end
  st.battMin, st.battMax = battRange.min, battRange.max
  inited = true
end

local function create(zone, options)
  if not inited then widgetInit() end
  return { zone = zone, options = options }
end

local function update(wgt, options)
  wgt.options = options
end

-- runs even when this screen isn't showing, so home/arm/trip tracking continues
local function background(wgt)
  local now = getTime()
  readSensors()
  updateLogic(now)
end

local function refresh(wgt, event, touchState)
  local z = wgt.zone
  if not inited then widgetInit() end
  -- Does any profile claim this RADIO? Ask before the zone test below: an
  -- unsupported panel is usually a small one too, and the zone checklist would
  -- send the pilot chasing Screens-setup toggles that cannot possibly help.
  if profileFor(z.w, z.h) == nil then
    drawTooSmall(z, true)
    return
  end
  -- Cheap reject for an obviously tiny zone, before building a layout for it.
  if z.w < 380 or z.h < 200 then
    drawTooSmall(z)
    return
  end
  local now = getTime()
  readSensors()
  updateLogic(now)
  st.L = getLayout(z)
  -- Wide enough, but too SHORT to be legible? (top bar / sliders / trims left on)
  -- Show the setup recipe rather than a squashed, misleading instrument.
  if not st.L.ok then
    drawTooSmall(z, st.L.badPanel)
    return
  end
  updateQR()             -- rebuilds on movement; only while the screen is visible
  drawScreen(st.L)
end

return {
  name       = "GPSQR",
  options    = {},
  create     = create,
  update     = update,
  refresh    = refresh,
  background = background,
  useLvgl    = false,
}
