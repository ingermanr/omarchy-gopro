# GoPro Webcam for Omarchy

Bar widget for [Omarchy](https://omarchy.org/) Quattro that controls a GoPro
connected over USB in **GoPro Connect** mode and uses it as a webcam through
`v4l2loopback`.

## What it does

- **Bar icon**: dimmed when the camera is off or disconnected, normal while
  streaming. Left click opens the panel, right click toggles the webcam.
- **Panel**: connection state and free SD space, webcam on/off, lens
  (wide / narrow / superview / linear), resolution (1080p / 720p / 480p),
  record, photo, and download of the newest SD card file to `~/Videos`.
- Record and photo are disabled while streaming and while the camera runs on
  USB power only, because the camera refuses both without a battery.

Everything runs through `bin/gopro-webcam`, a small bash helper shipped inside
this plugin. The QML resolves it relative to `Panel.qml`, so the plugin is
self-contained and works wherever it is installed.

## Requirements

- Omarchy Quattro (4.x) with the `omarchy plugin` commands.
- GoPro HERO12 in USB webcam mode. Other models using the same HTTP API are
  untested.
- `ffmpeg`, `curl`, `v4l2-utils` (`v4l2-ctl`) and the `v4l2loopback` kernel
  module.
- A battery in the camera for record and photo.

## Install

```bash
omarchy plugin add https://github.com/ingermanr/omarchy-gopro --enable
```

Validate the folder at any time:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/io.github.ingermanr.gopro
```

## Privileges

The helper creates the loopback device by running
`sudo modprobe v4l2loopback devices=1 video_nr=42 card_label="GoPro HERO12" exclusive_caps=1`
when `/dev/video42` is missing. That is the only privileged command in the
plugin, and it may prompt for your password the first time.

To avoid the prompt during a stream, load the module once at boot instead. This
is optional system setup, not something the plugin changes on its own:

```bash
echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf
printf 'options v4l2loopback devices=1 video_nr=42 card_label="GoPro HERO12" exclusive_caps=1\n' \
  | sudo tee /etc/modprobe.d/v4l2loopback.conf
```

## Settings

| Key | Default | Description |
| --- | --- | --- |
| `refreshIntervalSec` | `15` | Background status polling interval in seconds (5–3600). |

## Removal

```bash
omarchy plugin remove io.github.ingermanr.gopro
```

Removal deletes the plugin folder. Files already downloaded to `~/Videos` and
any module configuration you added under `/etc` are left untouched.

## Known limitations

- **Record and photo fail on current HERO12 firmware.** The camera answers
  HTTP 500 on `shutter/start`; the helper reports it clearly instead of
  pretending the shot happened. This is a firmware bug, not a plugin bug.
- Changing the lens while streaming restarts the stream internally. Switching
  to *linear* pre-streams in *wide* first, which can take a few seconds.
- Only one camera at a time: the loopback device is fixed at `/dev/video42`.

## License

MIT. See [LICENSE](LICENSE).
