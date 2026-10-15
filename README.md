# camera-nvr

Self-hosted NVR for a Yoosee C173 dual-lens WiFi camera. Frigate records locally;
recordings and event clips archive to a Cloudflare R2 bucket.

Built for a spare laptop (Intel integrated graphics) that lives with the camera
rather than travelling with you.

```
camera ──RTSP──> Frigate ──> local disk (2-day rolling)
                             │
                             └──rclone copy──> Cloudflare R2 (long-term archive)
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
| `R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | All three required — the sidecar refuses to start without them and names the missing one |
| `R2_BUCKET` | Archive bucket name |

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

1920×2160 is the **two lenses stitched into a single frame**. There are no
separate per-lens URLs — the "Double Screen and Double Channel" box claim is one
combined image, not two addressable streams.

---

## Cost

Measured from a real 10-second capture of this camera, not estimated:

| Stream | Bitrate | Per day | 90 days |
|---|---|---|---|
| Main 1920×2160 | 943 kbps | 9.49 GB | 854 GB |

R2 at $0.015/GB-month with **no egress fees**:

| Window | Size | Cost |
|---|---|---|
| 7 days | 66 GB | ~$1.01/mo |
| 30 days | 285 GB | ~$4.32/mo |
| 90 days | 854 GB | ~$12.96/mo |

Do not add compression. The stream is already HEVC; re-encoding costs CPU,
degrades the image, and **transcoded footage is weaker as evidence**.

---

## Retention

Local disk is a short rolling window (2 days). R2 is the archive of record.

`r2-sync.sh` uses **`rclone copy`, not `sync`** — deliberately. `sync` makes the
destination match the source exactly *including deletions*, so pointed at a
rolling local directory it would quietly erase the whole archive each time
retention lapsed. Expiry belongs to an R2 lifecycle policy:

```
prefix "record/"  expire after  90 days
prefix "events/"  expire after 365 days
```

Set those in the Cloudflare dashboard. They are deliberately not in the repo —
bucket policy is infrastructure, not code.

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
- Rotate the RTSP password if this one has ever been shared in the clear

---

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Frigate + r2-sync sidecar |
| `frigate/config.yml` | NVR config — validated against the real schema |
| `rclone/r2-sync.sh` | Archive pass (`copy`, never `sync`) |
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
| Nothing lands in R2 | Check `docker compose logs r2-sync` — it names the missing `R2_*` variable or rejects the credentials |