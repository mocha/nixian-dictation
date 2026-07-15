# Notification chimes

`dictation-toggle` plays a short sound at three moments:

| file        | when it plays                        |
|-------------|--------------------------------------|
| `start.mp3` | recording begins                     |
| `done.mp3`  | transcription delivered (success)    |
| `fail.mp3`  | recording/transcription failed/aborted |

The audio files themselves are **not committed** — they're personally licensed
(noncommercial) and this repo is public, so they're excluded via `.gitignore`. Drop your
own short mono clips with these names into this folder; the tool plays no chime if a file is
absent (a fresh clone just runs silent).

`pw-play` decodes the files, so any format it supports works (mp3, ogg, flac, wav). Override
the location or names with `DICTATION_SOUNDS` (dir) and `DICTATION_SND_START` /
`DICTATION_SND_STOP` / `DICTATION_SND_FAIL`, or silence everything with `DICTATION_NOSOUND=1`.
