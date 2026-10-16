# Findings — Yoosee C173 dual-lens WiFi camera

Everything below was established by measurement against the device, not assumed
from the packaging. Where a conclusion was wrong at first, that is recorded too.

---

## 1. Identity

| Field | Value |
|---|---|
| Box model | `C173-5-238` (not a recognisable model from any known maker) |
| Barcode | `6 835080 502380` — GS1 prefix for a Chinese export/private-label seller |
| FCC ID | `TA-2019-448` — generic grantee code, filed 2019 |
| ICASA | `TA-2019/448` — made for the **South African** market |
| Device label | `HX:A5GL` platform prefix, `QC:09` — per-unit serial redacted |
| Platform | **`HX` = Hangzhou XiongMai (XM) SDK** |
| App | `com.yoosee` v6.46.1, vendor namespace `com.jwkj.*` |
| Cloud | `api1.cloudlinks.cn`, `personalinfo.cloudlinks.cn`, `vasapi.cloudlinks.cn` |

The box calls it a "Dome Camera" while the artwork shows a **bullet** camera.
Box text and box art disagree — normal for white-label packaging.

**The `HX` prefix was the single most useful clue.** It was confirmed
independently from the network side by the `USER_CMD_SET` RTSP extension (XM
proprietary), busybox telnetd, and a Debian-style `/sbin/ftpd` inetd path.

---

## 2. Network surface — before RTSP was enabled

Full scan of all 65535 TCP ports. Four open:

| Port | Service | Note |
|---|---|---|
| 21 | FTP | **Broken** — `inetd: can't execute '/sbin/ftpd'` (binary absent) |
| 23 | Telnet | busybox telnetd, live `login:` prompt, auth required |
| 554 | RTSP | Stub — see below |
| 50000 | Proprietary | No banner. Speaks only on the correct XM binary handshake |

No web UI (80/8080), **no ONVIF (8899)**, no SSH, no media port (34567).

### The misleading RTSP stub

Port 554 answered with a byte-identical response to **everything** — including
`OPTIONS`, which it simultaneously advertised in its own `Allow` header:

```
RTSP/1.0 405 Method Not Allowed
Allow: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE,
       GET_PARAMETER, SET_PARAMETER, USER_CMD_SET
```

Tested and rejected: 51 paths (XM native, generic, ONVIF-style), three auth
modes, seven vendor `User-Agent` values. All `405`.

**The wrong conclusion:** this reads exactly like "RTSP is not available on this
firmware" — and that is what I said. It was wrong.

---

## 3. What actually unlocked it

Decompiling the APK (`com.yoosee` v6.46.1) and running `strings` over the 11 dex
files. `jadx` full decompile was still running when this was found — `strings`
got there first and was sufficient.

```
com.yoosee.RET_SET_RTSP / RET_SET_RTSP_TYPE      API to change RTSP state
com/jwkj/device_setting/ModifyRTSPPasswordActivity    the settings screen
PenetrateRTSPInfo / PenetrateRTSPPwd              cloud API for RTSP config
"After RTSP is enabled, you can access the device through the NVR, PC
 monitoring software CMS or other ONVIF-connected applications (need to be
 on the same LAN)"
"You must set a password when you turn on RTSP"
"You can re-enable in Settings - RTSP Settings"
```

**RTSP is not absent. It is disabled by default, and the vendor app has a toggle.**

```
Yoosee app -> tap camera -> Settings -> RTSP Settings -> enable + set password
```

The camera reboots afterwards. During that reboot the port scan briefly showed
only 554 and 50000 — services come and go as it restarts, so a failed retest
right after enabling is expected, not a real negative.

---

## 4. Working streams

Once enabled, the server changed behaviour observably: `Allow:` became `Public:`,
`OPTIONS` began returning `200`, and `DESCRIBE` began issuing `401` challenges.

| Path | Video | Audio |
|---|---|---|
| `/onvif1` | **HEVC 1920×2160 @25fps** | PCMA (G.711-A) 16 kHz mono |
| `/onvif2` | HEVC 864×976 @25fps | none |

Everything else returns `400`. The username is `admin` — **not** the app login.

**1920×2160 is two independent 1080p sensors stacked vertically — not one
stitched image.** This was stated wrongly here at first, as "the dual lens
stitched into one frame", which implies a seamless panorama. A frame extracted
from the capture disproved it:

```
┌─────────────────────────────┐
│ 15:47:11                    │  ← each half burns its OWN clock
│   sensor A — points at X    │
├─────────────────────────────┤  ← hard seam at y=1080, no blend
│ 15:47:14                    │  ← its own clock, 3 s apart
│   sensor B — points at Y    │
└─────────────────────────────┘
```

A stitch shares one clock and one scene. These are two imagers roughly 90° apart
in one housing, so **the frame holds two unrelated views**, and the effective
detail per sensor is 1920×1080. Any analysis must crop to one half first.

There are still no separate per-lens RTSP URLs. The "Double Screen and Double
Channel" box claim is marketing for this composite.

### Gotchas that will bite

| Symptom | Cause | Fix |
|---|---|---|
| Connects then `Invalid data found` | forced `-rtsp_transport tcp` | **drop it** — this server wants UDP |
| Credentials silently ignored | literal `@` in the password | percent-encode → `%40` |
| `405` on every path | RTSP not enabled in the app | Settings → RTSP Settings |
| `401` | wrong user — it is `admin`, not the app login | use `admin` |
| `400` | wrong path | only `/onvif1` and `/onvif2` |
| A tracked object is configured but never fires | label not in the model's labelmap | see §8 |

A password containing `@` must be encoded in the URL **everywhere** — Frigate
config, env vars, VLC, anything. For example `p@ss` → `p%40ss`. A literal `@`
truncates the credentials and fails silently rather than with a useful error.

---

## 5. Storage — measured, not guessed

Captured 10 s of each stream and measured with ffprobe:

| Stream | Bitrate | Per day | Per week | 30 days | 90 days |
|---|---|---|---|---|---|
| `/onvif1` 1920×2160 | **943 kbps** | 9.49 GB | 66.4 GB | 285 GB | 854 GB |
| `/onvif2` 864×976 | **214 kbps** | 2.15 GB | 15.1 GB | 64.5 GB | 194 GB |

The main figure is the whole container. Broken out with ffprobe, **128 kbps of it
is PCMA audio** — a fixed 1.29 GB/day, 471 GB/year, for a 16 kHz mono G.711
channel. The video is ~815 kbps.

### Local-only, so retention is a disk decision

This build originally archived to Cloudflare R2 and costed it there (~$13/month
for 90 days, no egress fees). R2 was then dropped in favour of local-only
recording, which removes the cost question and replaces it with a disk one:

| Days kept | Disk needed |
|---|---|
| 7 | 66 GB |
| 10 | 95 GB |
| 14 | 133 GB |
| 30 | 285 GB |
| 60 | 569 GB |
| 90 | 854 GB |

There is no lifecycle policy to fall back on any more — `FRIGATE_RETAIN_DAYS`
above the disk's capacity means Frigate evicts early rather than failing.

### Motion gating is useless here

The standard storage lever — record only on motion — does not apply to a poultry
house. Broilers peck and shuffle constantly, so motion fires on nearly every
frame. The pipeline records continuously and pays the full rate either way.

### Compression is the wrong lever

Compression buys nothing worth having here:

- The stream is **already HEVC** at 943 kbps for 4.1 megapixels. That is efficient.
- Re-encoding is HEVC→HEVC: typically 20–30% smaller at best, with visible
  quality loss and heavy CPU/GPU cost on a 1920×2160 source.
- **Transcoded footage is weaker as evidence** — in an insurance dispute or any
  proceeding, an untouched capture is worth materially more than a squeezed one.

Record untouched and let retention handle ageing. Note the reasoning is
analytic — the local FFmpeg build is `--disable-decoder=h264,hevc,vc1,vvc` (RPM
patent build), so re-encoding could not be benchmarked on this machine.

If storage must be cut, the honest levers are dropping the audio role (13.6%) or
recording the sub stream (4.4× smaller, at half the detail per sensor).

---

## 6. Security

**Port 23 telnet is open and offering a login shell.** Published XM factory
defaults were tested against `root` and `admin`
(`xmhdipc`, `xc3511`, `vizxv`, `juantech`, `hi3518`, `7ujMko0admin`, blank) —
**none worked**, so the password is not a known default. The surface should still
be removed:

1. Move the camera to a dedicated IoT SSID/VLAN with client isolation.
2. Block port 23 in the router's per-device firewall.
3. Never port-forward. RTSP is LAN-only and the camera is on the same flat
   network as every phone and laptop.

**Change the RTSP password.** It was shared in plaintext in conversation and
should not be reused as the app account password.

---

## 7. Why the cloud archive was dropped

The first build archived to Cloudflare R2 with an rclone sidecar. It was removed
in favour of local-only recording, because the footage is watched on the same
machine that captures it and an offsite copy answering no question the local one
did not.

The lesson from that build is kept because it generalises: **`rclone sync`
against a rolling source deletes the destination.** Frigate's local window ages
out, `sync` makes the destination match the source *exactly including deletions*,
and the entire archive is erased every time retention lapses — silently, while
reporting success. `copy` only adds and updates and can never delete; expiry
belongs to a lifecycle policy, not to a transfer.

That reasoning is preserved on the hivemind board. It is recorded here rather
than implemented, since nothing in this repo archives any more.

---

## 8. Two ways this build lied while looking fine

Both passed every check available when they were written. Both were caught only
by executing the real thing.

### 8.1 A label that silently does not exist

`objects.track: [person, vehicle]`. `vehicle` is a plausible English word and
Frigate's own docs use it — but the default model is
`ssdlite_mobilenet_v2` against `coco_91cl`, whose vehicle labels are `car`,
`bus`, `train`, `boat`, `motorcycle`. There is no `vehicle`.

Frigate does not error. It logs one WARNING, **drops the label from the track
list, and keeps running** — so the config validates, the UI looks configured, and
vehicle alerts simply never fire. The whole feature is absent while reporting
healthy.

Read the labelmap, not the docs:

```bash
docker run --rm --entrypoint sh ghcr.io/blakeblackshear/frigate:stable \
  -c "grep -nxE 'car|bus|truck|vehicle' /openvino-model/coco_91cl_bkgr.txt"
```

### 8.2 A bind mount turns a missing file into a directory

```yaml
volumes:
  - ./rclone/r2.conf:/config/r2.conf:ro
```

With `r2.conf` absent, Docker **creates a directory at that path** so the mount
succeeds. The documented fix — `cp r2.conf.template r2.conf` — then fails with
"is a directory", and `test -f /config/r2.conf` is false forever. The remedy for
the missing file makes the missing file permanent.

The same trap sits under any file bind mount, which is why the recordings mount
in `docker-compose.yml` points at a **directory** (`./media`) that is committed
empty via `.gitkeep`, rather than at a path Docker is left to invent.

### The shared shape

```
  config looks valid        ──>  validator passes
  nothing errors            ──>  service starts
  the feature is simply absent
```

Every validator answers "is this shaped correctly", never "does this work". A
config file is a claim about behaviour, and the only instrument that settles it
is running the real path.