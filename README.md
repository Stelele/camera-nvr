# camera-nvr

Self-hosted NVR for a Yoosee C173 dual-lens WiFi camera, recording **locally
only**. No cloud bucket, no offsite copy — the laptop that lives with the camera
is the archive.

Built for a spare laptop (Intel integrated graphics) watching a small broiler
house. Analysis of the footage is a separate project; this repo is the capture
pipeline.

```
camera ──RTSP──> Frigate ──> local disk (rolling window, default 14 days)
```

---

## Quick start

```bash
cp .env.example .env          # then edit it — see Configuration
docker compose up -d
```

Web UI: <http://localhost:5000>

**Validate before you trust it.** Frigate ships a validator — run it after any
config edit rather than discovering the mistake from a failed boot:

```bash
set -a; source .env; set +a          # the validator needs the substituted URLs
docker run --rm \
  -v "$PWD/frigate/config.yml:/config/config.yml:ro" \
  -e FRIGATE_CAM_MAIN_URL="$FRIGATE_CAM_MAIN_URL" \
  -e FRIGATE_CAM_SUB_URL="$FRIGATE_CAM_SUB_URL" \
  -e FRIGATE_RETAIN_DAYS="$FRIGATE_RETAIN_DAYS" \
  -e FRIGATE_SNAPSHOT_DAYS="$FRIGATE_SNAPSHOT_DAYS" \
  --entrypoint python3 ghcr.io/blakeblackshear/frigate:stable \
  -u -m frigate --validate-config
```

---

## Configuration

Everything sensitive lives in `.env` — that file is the only place a credential
is ever stored, and it is gitignored. No tracked file in this repo holds a
secret value, so the repository is safe to publish. Handling notes are at the top
of `.env` itself.

Fill these in before `docker compose up`:

| Variable | Notes |
|---|---|
| `CAM_RTSP_PASSWORD_ENCODED` | **Percent-encode it.** `@` must be `%40`; a literal `@` fails *silently* |
| `FRIGATE_CAM_MAIN_URL` / `_SUB_URL` | Built from the password above |
| `FRIGATE_MEDIA_PATH` | Point at a large disk on the laptop |
| `FRIGATE_RETAIN_DAYS` | This is the whole retention policy — see Storage |

Two gotchas that cost real time, both detailed in `.env`:

- The password contains `@`, which terminates the credentials section of a URL.
  `p@ss` must be written `p%40ss`, everywhere — a literal `@` truncates the
  credentials and fails *silently*, not with a useful error.
- The RTSP username is `admin`. Not your app login, not the device `ID`.

---

## What it records

| | Path | Resolution | Codec |
|---|---|---|---|
| Main | `/onvif1` | 1920×2160 @25fps | HEVC + PCMA audio |
| Detect | `/onvif2` | 864×976 @25fps | HEVC |

Detection runs on the sub stream, recording on the main stream. Running detection
on 1920×2160 would cost roughly ten times the CPU for no accuracy gain on a
fixed scene.

### The main stream is two cameras, not one wide shot

`1920×2160` is **two independent 1080p sensors stacked vertically**, and the two
halves are *not* a seamless stitch:

```
┌─────────────────────────────┐
│ 15:47:11                    │  ← its own clock overlay
│   sensor A — points at X    │
├─────────────────────────────┤  ← hard seam at y=1080, no blend
│ 15:47:14                    │  ← a different clock, 3s apart
│   sensor B — points at Y    │
└─────────────────────────────┘
        1920 × 2160
```

A stitch would share one clock and one scene. These are two imagers ~90° apart
sharing a housing, so **the frame contains two unrelated views**. Effective
detail per sensor is 1920×1080, not 1920×2160.

Consequences:

- Any analysis must **crop to one 1920×1080 half** first. Feeding a detector the
  full frame gives it two scenes at once.
- The "Double Screen and Double Channel" box claim is marketing for this
  composite, not two addressable streams. There are no per-lens RTSP URLs.

### Detection is deliberately minimal

Only `person` is tracked. A dense flock is not a set of countable objects to a
COCO detector — occlusion merges birds into blobs, and per-bird inference on CPU
is expensive for no gain. **Continuous recording is the pipeline**; object
tracking is there for the rare human.

Note the label list is checked against the model's labelmap, not assumed:
`vehicle` is not a COCO label at all and Frigate drops it with only a warning,
leaving the feature silently absent.

---

## Storage

Local disk is the only store, so retention is sized to the disk. Measured from a
real capture of this camera, not estimated:

| Stream | Bitrate | Per day | Per year |
|---|---|---|---|
| Main 1920×2160 (video + audio) | 943 kbps | 9.5 GB | 3.46 TB |
| — of which audio (PCMA 16 kHz) | 128 kbps | 1.3 GB | 471 GB |
| Main, video only | ~815 kbps | 8.2 GB | 3.0 TB |
| Sub 864×976 | 214 kbps | 2.2 GB | 785 GB |

Disk needed at each retention window (main stream):

| Days | Disk |
|---|---|
| 7 | 66 GB |
| 10 | 95 GB |
| 14 | 133 GB |
| 30 | 285 GB |
| 60 | 569 GB |
| 90 | 854 GB |

Two levers if that is too much:

- **Drop the `audio` role** in `frigate/config.yml` — saves 1.3 GB/day (13.6%),
  at the cost of never having the audio channel again. Irreversible, so decide
  before you start recording in earnest.
- **Record the sub stream instead** — 4.4× smaller, but 864×976 is half the
  detail and the composite is only 864×488 per sensor.

Do not transcode to save space. The stream is already HEVC; re-encoding is a
quality loss, a CPU cost on a laptop, and leaves you with weaker evidence than
the untouched capture.

---

## Retention

`FRIGATE_RETAIN_DAYS` is the entire policy. Frigate writes continuously and
evicts the oldest footage once the window is exceeded.

Recording is continuous rather than motion-gated on purpose: broilers move
constantly, so motion gating rejects almost nothing while making the resulting
archive harder to reason about. You get the storage cost either way.

---

## Hardware acceleration

Configured for Intel integrated graphics via VAAPI. Requires `/dev/dri` through
to the container, which `docker-compose.yml` already does.

If decoding fails on the laptop, try in order:

1. `preset-qsv` instead of `preset-vaapi` in `frigate/config.yml`
2. Confirm the host user is in the `render` and `video` groups
3. Drop `hwaccel_args` entirely — software decode is slower but always works

---

## Security — do this regardless

**Port 23 (telnet) is open on the camera.** Published XM factory defaults were
tested and none worked, so it is not a known default, but the surface is there.

- Put the camera on a dedicated IoT SSID/VLAN with client isolation
- Block port 23 in the router's per-device firewall
- **Never port-forward it.** RTSP is LAN-only and the camera sits on the same
  flat network as every phone and laptop
- Rotate the RTSP password if it has ever been shared in the clear

---

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Frigate |
| `frigate/config.yml` | NVR config — validated against the real schema |
| `docs/FINDINGS.md` | How the camera was reverse-engineered end to end |
| `scripts/rtsp_probe.sh` | Find a working RTSP URL on an unknown camera |
| `scripts/capture.sh` | Pull a clip once a URL is known |
| `scripts/telnet_auth.py` | Test telnet logins on an owned device |
| `scripts/pull_and_decompile.sh` | Pull an APK over adb and run jadx |

`scripts/` is standalone and runs against any camera — no Frigate required.
Credentials come from `$CAM_USER` / `$CAM_PASS` and are never written to disk.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `405` on every RTSP path | RTSP not enabled — app → Settings → RTSP Settings |
| `401 Unauthorized` | username must be `admin`, not the app login |
| `Invalid data found` | forced TCP transport; this camera wants UDP |
| Connects, no video | `@` in the password needs percent-encoding |
| `400 Bad Request` | wrong path — only `/onvif1` and `/onvif2` exist |
| Disk filling early | `FRIGATE_RETAIN_DAYS` larger than the disk allows |
| Nothing recorded | Check `docker compose logs frigate`; confirm `FRIGATE_MEDIA_PATH` exists and is writable |
