"""
Applet: Palisades Snow
Summary: Palisades Tahoe conditions
Description: Mid-mountain temps, surface conditions, snow forecast, weekend outlook, and I-80 / SR-89 chain controls for Palisades Tahoe.

Data:
  - NWS gridpoint forecast STO/89,87 (7,385 ft, mid-mountain)
  - USDA SNOTEL 784:CA:SNTL "Palisades Tahoe" (8,010 ft) for observed new snow + temps
  - Caltrans District 3 chain controls
"""

load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

TZ = "America/Los_Angeles"
NWS_GRID = "https://api.weather.gov/gridpoints/STO/89,87"
SNOTEL = "https://wcc.sc.egov.usda.gov/awdbRestApi/services/v1/data"
CALTRANS = "https://cwwp2.dot.ca.gov/data/d3/cc/ccStatusD03.json"
NWS_HEADERS = {"User-Agent": "palisades-snow-tidbyt (personal app)", "Accept": "application/geo+json"}

ICE = "#bfe3ff"
WHITE = "#e8e8e8"
GRAY = "#7a7a7a"
DIM = "#3a4656"
BLUE = "#4aa8ff"
AMBER = "#ffb02e"
RED = "#ff4d4d"
GREEN = "#3ddc6a"
YELLOW = "#ffd84a"
TODAY_BG = "#262626"
BEST_BG = "#0d2a48"
RULE = "#262626"

SMALL = "CG-pixel-3x5-mono"
BIG = "6x13"

FLAKE = ["10101", "01110", "11111", "01110", "10101"]
DEG = ["010", "101", "010"]
SUN = ["1001001", "0011100", "0111110", "1111111", "0111110", "0011100", "1001001"]
CLOUD = ["0001100", "0011110", "0111111", "1111111", "0000000", "0000000", "0000000"]
SNOW_CLOUD = ["0001100", "0011110", "0111111", "1111111", "0000000", "1001001", "0100100"]

# ---------- drawing helpers ----------

def at(x, y, child):
    return render.Padding(pad = (x, y, 0, 0), child = child)

def txt(s, color, font = SMALL):
    return render.Text(content = s, color = color, font = font)

def pix(rows, color):
    kids = []
    for y in range(len(rows)):
        row = rows[y]
        for x in range(len(row)):
            if row[x] == "1":
                kids.append(at(x, y, render.Box(width = 1, height = 1, color = color)))
    return render.Stack(children = kids)

def box(x, y, w, h, color):
    return at(x, y, render.Box(width = w, height = h, color = color))

def small_w(s):
    return 4 * len(s) - 1

def canvas(items):
    return render.Stack(children = [render.Box(width = 64, height = 32)] + items)

def header(tag):
    items = [at(1, 1, txt("PALISADES", ICE))]
    if tag == "*":
        items.append(at(58, 1, pix(FLAKE, ICE)))
    elif tag:
        items.append(at(64 - 4 * len(tag), 1, txt(tag, GRAY)))
    return items

def temp_items(x, y, t, color):
    s = "%d" % t
    return [at(x, y, txt(s, color)), at(x + 4 * len(s), y, pix(DEG, color))]

# ---------- units / time ----------

def c_to_f(c):
    return c * 9.0 / 5.0 + 32.0

def rnd(x):
    if x < 0:
        return -int(-x + 0.5)
    return int(x + 0.5)

def hours(n):
    return time.parse_duration("%dh" % n)

def dur_hours(d):
    # ISO 8601 duration like PT6H, P1D, P1DT6H
    total = 0
    body = d[1:]
    datepart, _, timepart = body.partition("T")
    if datepart.endswith("D"):
        total += int(datepart[:-1]) * 24
    num = ""
    for c in timepart.elems():
        if c.isdigit():
            num += c
        elif c == "H":
            total += int(num)
            num = ""
        else:
            num = ""
    return max(total, 1)

def day_key(t):
    return t.in_location(TZ).format("2006-01-02")

def hour_label(t):
    l = t.in_location(TZ)
    return l.format("3") + l.format("PM")[0]

def expand(values, split):
    """NWS (validTime, value) periods -> list of (hour_start, value)."""
    out = []
    for v in values:
        if v.get("value") == None:
            continue
        start, _, d = v["validTime"].partition("/")
        t0 = time.parse_time(start)
        n = dur_hours(d)
        val = v["value"] / n if split else v["value"]
        for i in range(n):
            out.append((t0 + hours(i), val))
    return out

def by_period_mid(values):
    """NWS periods keyed by local date of the period midpoint (for max/min temps)."""
    out = {}
    for v in values:
        if v.get("value") == None:
            continue
        start, _, d = v["validTime"].partition("/")
        t0 = time.parse_time(start)
        n = dur_hours(d)
        out[day_key(t0 + time.parse_duration("%dm" % (n * 30)))] = v["value"]
    return out

# ---------- data ----------

def fetch_nws():
    resp = http.get(NWS_GRID, headers = NWS_HEADERS, ttl_seconds = 900)
    if resp.status_code != 200:
        return None
    return resp.json()["properties"]

def fetch_snotel(now):
    # SNOTEL reports in fixed PST (UTC-8)
    pst_now = (now - hours(8)).in_location("UTC")
    begin = (pst_now - hours(50)).format("2006-01-02 15:04")
    end = pst_now.format("2006-01-02 15:04")
    url = "%s?stationTriplets=784:CA:SNTL&elements=SNWD,TOBS&duration=HOURLY&beginDate=%s&endDate=%s" % (
        SNOTEL,
        begin.replace(" ", "%20"),
        end.replace(" ", "%20"),
    )
    resp = http.get(url, ttl_seconds = 900)
    if resp.status_code != 200:
        return None
    body = resp.json()
    if not body:
        return None
    series = {}
    for el in body[0].get("data", []):
        code = el["stationElement"]["elementCode"]
        pts = []
        for v in el.get("values", []):
            if v.get("value") == None:
                continue

            # "2026-11-18 17:00" in PST -> real time
            t = time.parse_time(v["date"], format = "2006-01-02 15:04") + hours(8)
            pts.append((t, v["value"]))
        series[code] = pts
    return series

def fetch_roads():
    resp = http.get(CALTRANS, ttl_seconds = 600)
    if resp.status_code != 200:
        return None
    rank = {"R-0": 0, "R-1": 1, "R-2": 2, "R-3": 3}
    i80 = -1
    sr89 = -1
    for rec in resp.json().get("data", []):
        cc = rec["cc"]
        loc = cc["location"]
        status = cc["statusData"]["status"]
        if status not in rank:
            continue
        lat = float(loc["latitude"])
        lon = float(loc["longitude"])
        r = rank[status]

        # I-80 eastbound from Applegate up to Truckee (the SF -> Palisades drive)
        if loc["route"] == "I-80" and loc["direction"] == "East" and lon > -121.0 and lon < -120.19:
            i80 = max(i80, r)

        # SR-89 between Truckee and Olympic Valley
        if loc["route"] == "SR-89" and lat > 39.19 and lat < 39.33 and lon > -120.215 and lon < -120.19:
            sr89 = max(sr89, r)
    return {"i80": i80, "sr89": sr89}

# ---------- analysis ----------

def build_days(nws, now):
    temps = [(t, c_to_f(v)) for (t, v) in expand(nws["temperature"]["values"], False)]
    snow = [(t, v / 25.4) for (t, v) in expand(nws["snowfallAmount"]["values"], True)]
    gusts = [(t, v * 0.621371) for (t, v) in expand(nws["windGust"]["values"], False)]
    sky = expand(nws["skyCover"]["values"], False)
    maxes = by_period_mid(nws["maxTemperature"]["values"])
    mins = by_period_mid(nws["minTemperature"]["values"])

    local_now = now.in_location(TZ)
    days = []
    for i in range(7):
        d = local_now + hours(24 * i)
        key = day_key(d)
        day_hours = [(t, f) for (t, f) in temps if day_key(t) == key and int(t.in_location(TZ).format("15")) >= 8 and int(t.in_location(TZ).format("15")) <= 16]
        if key in maxes:
            hi = c_to_f(maxes[key])
        elif day_hours:
            hi = max([f for (_, f) in day_hours])
        else:
            hi = None
        lo = c_to_f(mins[key]) if key in mins else None
        total = 0.0
        for (t, v) in snow:
            if day_key(t) == key:
                total += v
        g = [v for (t, v) in gusts if day_key(t) == key and int(t.in_location(TZ).format("15")) >= 8 and int(t.in_location(TZ).format("15")) <= 16]
        days.append({
            "key": key,
            "name": d.format("Mon").upper(),
            "date": d.format("Jan 2").upper(),
            "hi": hi,
            "lo": lo,
            "snow": total,
            "gust": max(g) if g else 0,
            "hours": day_hours,
        })

    cur_temp = None
    cur_sky = 50
    cur_snow = 0.0
    for (t, f) in temps:
        if t <= now and now < t + hours(1):
            cur_temp = f
    for (t, v) in sky:
        if t <= now and now < t + hours(1):
            cur_sky = v
    for (t, v) in snow:
        if t <= now and now < t + hours(1):
            cur_snow = v
    if cur_temp == None and days[0]["hours"]:
        cur_temp = days[0]["hours"][0][1]

    return days, {"temp": cur_temp, "sky": cur_sky, "snow_rate": cur_snow}

def snotel_stats(series, now):
    out = {"new24": 0, "new48": 0, "yest_hi": None, "night_lo": None}
    if not series:
        return out
    depth = series.get("SNWD", [])
    if depth:
        cur = depth[-1][1]
        d24 = [v for (t, v) in depth if t >= now - hours(24)]
        d48 = [v for (t, v) in depth if t >= now - hours(48)]
        if d24:
            out["new24"] = max(0, rnd(cur - min(d24)))
        if d48:
            out["new48"] = max(0, rnd(cur - min(d48)))
    tobs = series.get("TOBS", [])
    yest = [v for (t, v) in tobs if t >= now - hours(36) and t < now - hours(12)]
    night = [v for (t, v) in tobs if t >= now - hours(18)]
    if yest:
        out["yest_hi"] = max(yest)
    if night:
        out["night_lo"] = min(night)
    return out

def first_hour_at(day_hours, threshold):
    for (t, f) in day_hours:
        if f >= threshold:
            return hour_label(t)
    return None

def temp_color(t, slush):
    if t == None:
        return GRAY
    if t >= slush:
        return AMBER
    if t >= 38:
        return WHITE
    return BLUE

def surface_call(today, cur, obs, slush):
    hi = today["hi"]
    if hi == None:
        hi = cur["temp"] or 32
    night_lo = obs["night_lo"]
    if night_lo == None:
        night_lo = today["lo"] if today["lo"] != None else 28
    yest_hi = obs["yest_hi"] if obs["yest_hi"] != None else hi

    if cur["snow_rate"] >= 0.1:
        return ("SNOWING NOW", BLUE)
    if obs["new24"] >= 3 and hi < 36:
        return ("FRESH %d\" 24H" % obs["new24"], BLUE)

    # No overnight refreeze -> the snow never set up, slush comes sooner
    slush_eff = slush - 3 if night_lo > 32 else slush
    if hi >= slush_eff:
        when = first_hour_at(today["hours"], slush_eff - 4)
        return ("SLUSHY BY %s" % when if when else "SLUSHY PM", AMBER)
    if hi >= 38:
        if night_lo <= 30:
            when = first_hour_at(today["hours"], 34)
            return ("SOFTENS %s" % when if when else "SOFTENS PM", WHITE)
        return ("SOFT ALL DAY", WHITE)
    if night_lo < 30 and yest_hi >= 38:
        return ("FIRM AM" if hi >= 34 else "FIRM ALL DAY", WHITE)
    if obs["new48"] >= 3:
        return ("FRESH %d\" 48H" % obs["new48"], BLUE)
    return ("PACKED", WHITE)

def best_day_index(days, slush, threshold):
    snows = [d["snow"] for d in days]
    top = max(snows)
    if top >= 2:
        return snows.index(top)
    best = None
    best_score = 999
    for i in range(len(days)):
        d = days[i]
        if d["hi"] == None or d["gust"] >= 50:
            continue
        if d["hi"] < 34 or d["hi"] >= slush:
            continue
        score = abs(d["hi"] - 38)
        if score < best_score:
            best_score = score
            best = i
    return best

# ---------- frames ----------

def frame_now(today, cur, obs, slush):
    t = rnd(cur["temp"]) if cur["temp"] != None else None
    items = header("NOW")
    if t != None:
        s = "%d" % t
        color = temp_color(t, slush)
        items.append(at(1, 9, txt(s, color, BIG)))
        items.append(at(1 + 6 * len(s) + 1, 10, pix(DEG, color)))

    if cur["snow_rate"] >= 0.05:
        icon = pix(SNOW_CLOUD, ICE)
    elif cur["sky"] < 30:
        icon = pix(SUN, YELLOW)
    elif cur["sky"] < 70:
        icon = pix(CLOUD, WHITE)
    else:
        icon = pix(CLOUD, GRAY)
    items.append(at(56, 9, icon))

    if today["hi"] != None:
        items.append(at(34, 9, txt("H", GRAY)))
        items += temp_items(38, 9, rnd(today["hi"]), temp_color(today["hi"], slush))
    if today["lo"] != None or obs["night_lo"] != None:
        lo = obs["night_lo"] if obs["night_lo"] != None else today["lo"]
        items.append(at(34, 16, txt("L", GRAY)))
        items += temp_items(38, 16, rnd(lo), temp_color(lo, slush))

    call, color = surface_call(today, cur, obs, slush)
    items.append(at(1, 26, txt(call, color)))
    return canvas(items)

def frame_next_snow(days, threshold):
    idx = None
    for i in range(len(days)):
        if days[i]["snow"] >= threshold:
            idx = i
            break
    if idx == None:
        return None
    d = days[idx]
    amt = "%d" % rnd(d["snow"])

    # storm total = contiguous days with 1"+ around the big day
    lo_i = idx
    for _ in range(idx):
        if lo_i > 0 and days[lo_i - 1]["snow"] >= 1:
            lo_i -= 1
        else:
            break
    hi_i = idx
    for _ in range(len(days)):
        if hi_i < len(days) - 1 and days[hi_i + 1]["snow"] >= 1:
            hi_i += 1
        else:
            break
    total = 0
    for i in range(lo_i, hi_i + 1):
        total += days[i]["snow"]

    items = header("SNOW")
    items.append(at(1, 9, txt(amt, BLUE, BIG)))
    items.append(at(1 + 6 * len(amt) + 1, 10, txt("\"", BLUE)))
    name = "TODAY" if idx == 0 else d["name"]
    items.append(at(64 - small_w(name) - 1, 10, txt(name, WHITE)))
    items.append(at(64 - small_w(d["date"]) - 1, 17, txt(d["date"], GRAY)))
    if rnd(total) > rnd(d["snow"]):
        items.append(at(1, 26, txt("STORM TOTAL %d\"" % rnd(total), GRAY)))
    elif d["hi"] != None:
        items.append(at(1, 26, txt("HIGH", GRAY)))
        items += temp_items(21, 26, rnd(d["hi"]), WHITE)
    return canvas(items)

def frame_four_day(days, slush, threshold):
    items = header("*")
    best = best_day_index(days[:4], slush, threshold)
    for i in range(4):
        d = days[i]
        cx = i * 16
        if i == best:
            items.append(box(cx, 8, 16, 24, BEST_BG))
        elif i == 0:
            items.append(box(cx, 8, 16, 24, TODAY_BG))
        label_color = WHITE if (i == 0 or i == best) else GRAY
        items.append(at(cx + 2, 10, txt(d["name"], label_color)))
        if d["hi"] != None:
            items += temp_items(cx + 2, 17, rnd(d["hi"]), temp_color(d["hi"], slush))
        s = rnd(d["snow"])
        snow_s = "%d\"" % s if s >= 1 else "-"
        items.append(at(cx + (16 - small_w(snow_s)) // 2, 24, txt(snow_s, BLUE if s >= 1 else DIM)))
    return canvas(items)

def day_word(d, prev, slush, threshold):
    if d["snow"] >= threshold:
        return ("POW", BLUE)
    if d["snow"] >= 1:
        return ("SNOW", ICE)
    if d["hi"] != None and d["hi"] >= slush:
        return ("SLUSH", AMBER)
    if d["hi"] != None and d["hi"] >= 38:
        return ("SOFT", WHITE)

    # Refrozen: yesterday got soft/slushy, today stays cold
    if prev != None and prev["hi"] != None and prev["hi"] >= 38 and prev["snow"] < 1:
        return ("FIRM", GRAY)
    return ("PACKED", WHITE)

def frame_weekend(days, slush, threshold):
    wk = [i for i in range(1, len(days)) if days[i]["name"] in ("SAT", "SUN")][:2]
    if len(wk) < 2:
        return None
    items = header("WKND")
    worst = None
    for r in range(2):
        d = days[wk[r]]
        y = 9 + 7 * r
        items.append(at(1, y, txt(d["name"], WHITE)))
        if d["hi"] != None:
            items += temp_items(14, y, rnd(d["hi"]), temp_color(d["hi"], slush))
        s = rnd(d["snow"])
        items.append(at(27, y, txt("%d\"" % s if s >= 1 else "-", BLUE if s >= 1 else DIM)))
        word, wc = day_word(d, days[wk[r] - 1], slush, threshold)
        items.append(at(64 - small_w(word) - 1, y, txt(word, wc)))
        if worst == None or d["gust"] > worst["gust"]:
            worst = d
    items.append(box(0, 23, 64, 1, RULE))
    if worst["gust"] >= 40:
        items.append(at(1, 26, txt("KT22 HOLD RISK", RED)))
    else:
        items.append(at(1, 26, txt("GUSTS %d MPH" % rnd(worst["gust"]), GRAY)))
    return canvas(items)

def road_status(r):
    if r <= 0:
        return ("OPEN", GREEN)
    if r == 1:
        return ("R1 CHAINS", YELLOW)
    if r == 2:
        return ("R2 CHAINS", AMBER)
    return ("R3 CHAINS", RED)

def frame_roads(roads):
    if roads == None or max(roads["i80"], roads["sr89"]) <= 0:
        return None
    items = header("ROAD")
    s1, c1 = road_status(roads["i80"])
    s2, c2 = road_status(roads["sr89"])
    items.append(at(1, 9, txt("I-80", WHITE)))
    items.append(at(24, 9, txt(s1, c1)))
    items.append(at(1, 16, txt("SR-89", WHITE)))
    items.append(at(24, 16, txt(s2, c2)))
    items.append(box(0, 23, 64, 1, RULE))
    worst = max(roads["i80"], roads["sr89"])
    note = {1: "SNOW TIRES OK", 2: "AWD+SNOWTIRE OK", 3: "CHAINS ALL CARS"}[worst]
    items.append(at(1, 26, txt(note, GRAY)))
    return canvas(items)

def frame_error(msg):
    return canvas(header("*") + [at(1, 14, txt(msg, GRAY))])

# ---------- main ----------

def main(config):
    slush = int(config.get("slush", "44"))
    threshold = int(config.get("snow_threshold", "6"))
    show_weekend = config.bool("show_weekend", True)
    show_roads = config.bool("show_roads", True)

    now = time.now()
    nws = fetch_nws()
    if nws == None:
        return render.Root(child = frame_error("NO FORECAST"))

    days, cur = build_days(nws, now)
    obs = snotel_stats(fetch_snotel(now), now)

    frames = [frame_now(days[0], cur, obs, slush)]
    f = frame_next_snow(days, threshold)
    if f:
        frames.append(f)
    frames.append(frame_four_day(days, slush, threshold))

    weekday = now.in_location(TZ).format("Mon")
    if show_weekend and weekday in ("Wed", "Thu", "Fri"):
        f = frame_weekend(days, slush, threshold)
        if f:
            frames.append(f)
    if show_roads:
        f = frame_roads(fetch_roads())
        if f:
            frames.append(f)

    # Hidden dev option: ?frame=N shows a single frame
    only = config.get("frame")
    if only != None and only.isdigit() and int(only) < len(frames):
        return render.Root(child = frames[int(only)])

    return render.Root(
        delay = 15000 // len(frames),
        show_full_animation = True,
        child = render.Animation(children = frames),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "slush",
                name = "Slush line",
                desc = "Mid-mountain high (°F) at which snow turns slushy.",
                icon = "temperatureHigh",
                default = "44",
                options = [schema.Option(display = "%d°F" % t, value = "%d" % t) for t in range(38, 51, 2)],
            ),
            schema.Dropdown(
                id = "snow_threshold",
                name = "Snow day",
                desc = "Daily snowfall that counts as a real snow day.",
                icon = "snowflake",
                default = "6",
                options = [schema.Option(display = "%d in" % n, value = "%d" % n) for n in [2, 4, 6, 8, 10, 12]],
            ),
            schema.Toggle(
                id = "show_weekend",
                name = "Weekend outlook",
                desc = "Show Sat/Sun outlook Wednesday through Friday.",
                icon = "calendar",
                default = True,
            ),
            schema.Toggle(
                id = "show_roads",
                name = "Chain controls",
                desc = "Show I-80 and SR-89 chain controls when they're up.",
                icon = "car",
                default = True,
            ),
        ],
    )
