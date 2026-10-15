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

**1920×2160 is the dual lens stitched into one frame** — two 1080p sensors.
There are no separate per-lens RTSP URLs. The "Double Screen and Double Channel"
box claim is marketing for a single combined image, not two addressable streams.

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

### Cloudflare R2 cost

Storage is $0.015/GB-month with **no egress fees** — that is R2's whole
advantage, and it is what makes offsite surveillance archive viable.

| Window | Size | Storage | Writes | Total |
|---|---|---|---|---|
| 7 days | 66 GB | $1.00 | $0.01 | **~$1.01/mo** |
| 30 days | 285 GB | $4.27 | $0.05 | **~$4.32/mo** |
| 90 days | 854 GB | $12.81 | $0.16 | **~$12.96/mo** |

### Compression is the wrong lever

Three months of complete offsite archive costs **about $13/month**. Compression
buys nothing worth having:

- The stream is **already HEVC** at 943 kbps for 4.1 megapixels. That is efficient.
- Re-encoding is HEVC→HEVC: typically 20–30% smaller at best, with visible
  quality loss and heavy CPU/GPU cost on a 1920×2160 source.
- **Transcoded footage is weaker as evidence** — in an insurance dispute or any
  proceeding, an untouched capture is worth materially more than a squeezed one.

Recommendation: record untouched, archive untouched, let retention policy handle
ageing. Note this figure is analytic — the local FFmpeg build is
`--disable-decoder=h264,hevc,vc1,vvc` (RPM patent build), so re-encoding could
not actually be benchmarked on this machine.

If storage must be cut instead, record the **sub** stream (4.4× smaller) — but
864×976 is too low to identify anyone, so that trades the point of the camera.

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

## 7. The `rclone copy` vs `rclone sync` trap

The most dangerous bug in this build is the one that does not error.

Frigate keeps a short rolling local window. `rclone sync` makes the destination
match the source *exactly*, **including deletions**. Point it at a rolling local
directory and it will erase the entire R2 archive every time local retention
lapses — silently, while appearing to succeed.

`r2-sync.sh` therefore uses **`rclone copy`**, which only adds and updates.
Expiry is an R2 lifecycle policy on the bucket, not a side effect of a sync.

### R2 + AWS SDK note

R2 does not implement the streaming chunked payload the AWS SDK negotiates by
default (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`) — hence
`DisablePayloadSigning = true` in `njeremoto-operations`. **rclone is not the AWS
SDK and never negotiates it**, so no equivalent flag is needed. That discrepancy
is precisely why rclone is the right tool here.

---

## 8. Three ways this build lied while looking fine

Every one of these passed every check available at the time it was written. All
three were caught only by executing the real thing.

### 8.1 A label that silently does not exist

`objects.track: [person, vehicle]`. `vehicle` is a plausible English word and
Frigate's own docs use it — but the default model is
`ssdlite_mobilenet_v2` against `coco_91cl`, whose labels are `car`, `bus`,
`train`, `boat`, `motorcycle`. There is no `vehicle`.

Frigate does not error. It logs one WARNING, **drops the label from the track
list, and keeps running** — so the config validates, the UI looks configured, and
vehicle alerts simply never fire. The whole feature is absent while reporting
healthy.

Read the labelmap, not the docs:

```bash
docker run --rm --entrypoint sh ghcr.io/blakeblackshear/frigate:stable \
  -c "grep -nxE 'car|bus|truck|vehicle' /openvino-model/coco_91cl_bkgr.txt"
```

### 8.2 A config file that was mounted but never read

The sidecar mounted the rclone config at `/config/r2.conf` and ran bare
`rclone copy`. rclone does **not** look there — its default is
`/config/rclone/rclone.conf`. With no config found it prints

```
NOTICE: Config file "/config/rclone/rclone.conf" not found - using defaults
```

and then every command fails with `didn't find section in config file ("r2")` —
an error about the *remote*, when the real problem is the file's location. The
upload never worked and the log blamed the credentials.

Two traps stacked here: the wrong path, and `/config` not existing in the
`rclone/rclone` image at all, so writing the config failed too.

Fix: export `RCLONE_CONFIG` explicitly and `mkdir -p` its directory.

### 8.3 A bind mount that turns a missing file into a directory

```yaml
volumes:
  - ./rclone/r2.conf:/config/r2.conf:ro
```

With `r2.conf` absent, Docker **creates a directory at that path** so the mount
succeeds. Now `cp r2.conf.template r2.conf` fails ("is a directory"), and
`test -f /config/r2.conf` is false forever. The fix for the missing file makes
the missing file permanent.

Removed by not bind-mounting the config at all — it is generated at run time
from `R2_*` in `.env`, which also removes the second place to keep secrets.

### The shared shape

```
  config looks valid        ──>  validator passes
  nothing errors            ──>  service starts
  the feature is simply absent
```

Every validator answers "is this shaped correctly", never "does this work". A
config file is a claim about behaviour, and the only instrument that settles it
is running the real path — which is why §7's `copy`/`sync` distinction had to be
reasoned about rather than discovered by a crash.