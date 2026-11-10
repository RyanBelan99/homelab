# Usage: fastlist.py <name> <i.mjh.nz folder> <jmp2.uk stream template> <chno offset>
import gzip, json, os, sys, urllib.request

name, folder, stream, offset = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
SOURCE = f"https://i.mjh.nz/{folder}/.channels.json.gz"
REGION = "us"
MIN_CHANNELS = 100  # a smaller list means the source broke; keep the old file
OUT = f"/m3us/{name}-us.m3u"

req = urllib.request.Request(SOURCE, headers={"User-Agent": "homelab-playlist/1"})
with urllib.request.urlopen(req, timeout=60) as resp:
    data = json.loads(gzip.decompress(resp.read()))

channels = data["regions"][REGION]["channels"]
playable = sorted(
    ((cid, ch) for cid, ch in channels.items() if not ch.get("license_url")),
    key=lambda item: item[1]["chno"],
)
if len(playable) < MIN_CHANNELS:
    sys.exit(f"{name}: only {len(playable)} playable channels in {SOURCE}, keeping the old playlist")

def attr(value):
    return str(value).replace('"', "'")

lines = ["#EXTM3U"]
for cid, ch in playable:
    lines.append(
        f'#EXTINF:-1 tvg-id="{cid}" tvg-chno="{ch["chno"] + offset}" '
        f'tvg-name="{attr(ch["name"])}" tvg-logo="{attr(ch.get("logo", ""))}" '
        f'group-title="{attr(ch.get("group", ""))}",{ch["name"]}'
    )
    lines.append(stream.format(id=cid))

tmp = OUT + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
os.replace(tmp, OUT)
print(f"{name}: wrote {len(playable)} of {len(channels)} channels to {OUT}")
