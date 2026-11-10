import json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

API = os.environ["DISPATCHARR_URL"]
KEY = os.environ["DISPATCHARR_API_KEY"]
# Priority order: the first source defines a channel; later ones are failovers.
SOURCES = [
    {"m3u": "/data/m3us/plutotv-us.m3u",
     "epg_name": "Pluto TV", "epg_url": "https://i.mjh.nz/PlutoTV/us.xml.gz"},
    {"m3u": "/data/m3us/samsungtvplus-us.m3u",
     "epg_name": "Samsung TV Plus", "epg_url": "https://i.mjh.nz/SamsungTVPlus/us.xml.gz"},
]
MIN_STREAMS = 500  # fewer means a source broke; change nothing

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "X-API-Key": KEY, "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path}: HTTP {e.code} {e.read().decode()[:300]}")

def get_all(path):
    # Handles paginated and plain list responses.
    out = api("GET", path + ("&" if "?" in path else "?") + "page_size=10000")
    if isinstance(out, list):
        return out
    items = out["results"]
    while out.get("next"):
        nxt = urllib.parse.urlsplit(out["next"])
        out = api("GET", nxt.path + "?" + nxt.query)
        items += out["results"]
    return items

def wait(what, check, timeout=900):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = check()
        if result:
            return result
        time.sleep(5)
    sys.exit(f"timed out waiting for {what}")

def key(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())

# 0. Serve the channel list, guide and streams to the pod network only.
POD_ONLY = os.environ["POD_CIDR"] + ",127.0.0.0/8,::1/128"
network = next(s for s in get_all("/api/core/settings/") if s["key"] == "network_access")
want_network = {**(network["value"] or {}), "M3U_EPG": POD_ONLY, "STREAMS": POD_ONLY}
if network["value"] != want_network:
    api("PATCH", f"/api/core/settings/{network['id']}/", {"value": want_network})
    print(f"limited channel list, guide and streams to {POD_ONLY}")

# 1. Refresh both playlists (Dispatcharr creates a source per watched file).
accounts = {}
for src in SOURCES:
    acct = wait(f"M3U source for {src['m3u']}", lambda: next(
        (a for a in get_all("/api/m3u/accounts/") if a.get("file_path") == src["m3u"]), None), 300)
    before = acct["updated_at"]
    api("POST", f"/api/m3u/refresh/{acct['id']}/")
    acct = wait(f"refresh of {src['m3u']}", lambda: (
        lambda a: a if a["status"] in ("success", "error") and a["updated_at"] != before else None
    )(api("GET", f"/api/m3u/accounts/{acct['id']}/")))
    if acct["status"] != "success":
        sys.exit(f"refresh of {src['m3u']} failed: {acct.get('last_message')}")
    accounts[acct["id"]] = src
    print(f"refreshed {src['m3u']}: {acct.get('last_message', '')[:120]}")

# 2. Ensure each guide source exists. The guides only reach a few hours ahead.
EPG_REFRESH_HOURS = 2
epg_sources = {s["url"]: s for s in get_all("/api/epg/sources/")}
for src in SOURCES:
    if src["epg_url"] not in epg_sources:
        epg_sources[src["epg_url"]] = api("POST", "/api/epg/sources/", {
            "name": src["epg_name"], "source_type": "xmltv", "url": src["epg_url"],
            "is_active": True, "refresh_interval": EPG_REFRESH_HOURS})
        print(f"created guide source {src['epg_name']}")
    elif epg_sources[src["epg_url"]].get("refresh_interval") != EPG_REFRESH_HOURS:
        api("PATCH", f"/api/epg/sources/{epg_sources[src['epg_url']]['id']}/",
            {"refresh_interval": EPG_REFRESH_HOURS})
        print(f"set {src['epg_name']} guide refresh to every {EPG_REFRESH_HOURS}h")
    src["epg_id"] = epg_sources[src["epg_url"]]["id"]
epg_ids = {(e["epg_source"], e["tvg_id"]): e["id"] for e in get_all("/api/epg/epgdata/")}

# 3. Group the streams by channel name, in priority order.
order = {acct_id: i for i, acct_id in enumerate(accounts)}
all_streams = get_all("/api/channels/streams/")
stream_account = {s["id"]: s["m3u_account"] for s in all_streams}
streams = [s for s in all_streams
           if s["m3u_account"] in accounts and not s.get("is_stale")]
if len(streams) < MIN_STREAMS:
    sys.exit(f"only {len(streams)} streams, expected at least {MIN_STREAMS}; changing nothing")
groups = {}
for s in sorted(streams, key=lambda s: (order[s["m3u_account"]], s.get("stream_chno") or 1e9, s["id"])):
    groups.setdefault(key(s["name"]), []).append(s)

# Streamlink picks one quality plus audio (FFmpeg's default relays them all).
# hls:// because Samsung's links lack .m3u8; --hls-audio-select skips Pluto's
# audio-description track.
profile = {
    "name": "Streamlink HLS",
    "command": "streamlink",
    "parameters": "--http-header User-Agent={userAgent} --hls-audio-select 'english [original]' "
                  "--ffmpeg-fout mpegts --stdout hls://{streamUrl} best",
    "is_active": True,
}
existing_profile = next((p for p in get_all("/api/core/streamprofiles/") if p["name"] == profile["name"]), None)
if existing_profile is None:
    existing_profile = api("POST", "/api/core/streamprofiles/", profile)
    print(f"created stream profile {profile['name']}")
elif any(existing_profile.get(f) != v for f, v in profile.items()):
    existing_profile = api("PATCH", f"/api/core/streamprofiles/{existing_profile['id']}/", profile)
    print(f"updated stream profile {profile['name']}")
STREAM_PROFILE = existing_profile["id"]

logos = {l["url"]: l["id"] for l in get_all("/api/channels/logos/")}

def logo_id(stream):
    url = stream.get("logo_url")
    if not url:
        return None
    if url not in logos:
        logos[url] = api("POST", "/api/channels/logos/", {"name": stream["name"], "url": url})["id"]
    return logos[url]

# Duplicate numbers get the next free decimal (250, 250.1).
numbers = {}
taken = set()
for k, group in sorted(groups.items(), key=lambda kv: (kv[1][0].get("stream_chno") or 1e9, kv[0])):
    n = group[0].get("stream_chno")
    if n is not None:
        while n in taken:
            n = round(n + 0.1, 1)
        taken.add(n)
    numbers[k] = n

def desired(k, group):
    first = group[0]
    epg = next((epg_ids[(accounts[s["m3u_account"]]["epg_id"], s["tvg_id"])] for s in group
                if (accounts[s["m3u_account"]]["epg_id"], s["tvg_id"]) in epg_ids), None)
    return {
        "name": first["name"],
        "channel_number": numbers[k],
        "channel_group_id": first["channel_group"],
        "tvg_id": first["tvg_id"],
        "epg_data_id": epg,
        "streams": [s["id"] for s in group],
        "logo_id": logo_id(first),
        "stream_profile_id": STREAM_PROFILE,
    }

# 4. Reconcile channels. Only channels from these playlists (or with no
#    streams left) are touched; other sources' channels are left alone.
def ours(ch):
    return not ch["streams"] or any(stream_account.get(s) in accounts for s in ch["streams"])

existing = {}
duplicates = []
for ch in filter(ours, get_all("/api/channels/channels/")):
    k = key(ch["name"])
    (duplicates.append(ch["id"]) if k in existing else existing.__setitem__(k, ch))
created = updated = 0
for k, group in groups.items():
    want = desired(k, group)
    have = existing.get(k)
    if have is None:
        api("POST", "/api/channels/channels/", want)
        created += 1
        continue
    change = {f: v for f, v in want.items() if have.get(f) != v}
    if change:
        api("PATCH", f"/api/channels/channels/{have['id']}/", change)
        updated += 1
stale = [ch["id"] for k, ch in existing.items() if k not in groups] + duplicates
if stale:
    api("DELETE", "/api/channels/channels/bulk-delete/", {"channel_ids": stale})
# Guide data is only stored for linked channels, so re-import after changes.
if created or updated:
    for src in SOURCES:
        api("POST", "/api/epg/import/", {"id": src["epg_id"]})
    print("re-importing guides for new or changed channels")
failover = sum(1 for g in groups.values() if len(g) > 1)
print(f"sync: {len(groups)} channels from {len(streams)} streams ({failover} with a failover stream); "
      f"{created} created, {updated} updated, {len(stale)} deleted")
