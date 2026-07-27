# Media fixtures

Only deterministic, generated media fixtures belong here. Never use a captured
device screen, screenshot, packet trace, or personal content.

`solid-green-*` describes one synthetic 64 × 64 green HEVC keyframe. The
source Annex-B stream is reproducible with:

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'color=c=0x22CC88:s=64x64:r=1:d=1' \
  -frames:v 1 -pix_fmt yuv420p -c:v libx265 -preset medium \
  -x265-params 'lossless=1:keyint=1:min-keyint=1:no-scenecut=1:repeat-headers=1:annexb=1:aud=0:info=0:hash=0:log-level=error:pools=none:frame-threads=1:wpp=0' \
  -f hevc solid-green.hevc
```

The generated stream is 162 bytes with SHA-256
`d54a4fd5ba1d3db4f3396b754b73929471c7624081a0fc34377e8194012b75b9`.
The Base64 files contain the Annex-B stream’s VPS, SPS, and PPS without start
codes, plus its one VCL NAL unit with a four-byte big-endian length prefix.

`solid-blue-*` uses the same command and encoder settings with
`color=c=0x3355FF:s=96x64:r=1:d=1`. Its 174-byte Annex-B stream has SHA-256
`9f4c03ceff3e221312dca66ed6babe1bf4b2cbb3367f653a5be2f08b3588f0e5`.
The different SPS exercises atomic decoder replacement without using captured
content.
