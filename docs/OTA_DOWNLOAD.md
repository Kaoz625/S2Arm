# OTA resource-pack download (wireless install)

Lets the multi-game container app download a game's resource pack over HTTPS, with no
cable and no Mac nearby. The device ends up in exactly the state a USB push
(`tools/push_pack.py`) leaves it in, and the existing import gate
(`runtime/src/pack_apply.c`, `s2a_import_gate`) unpacks it the first time you tap Play.
The downloader itself never unpacks anything.

## 1. Export a pack on the Mac

```
python3 tools/ota_pack.py export <pack_dir> <out_dir> --title-id <16-hex title id>
# e.g. <pack_dir> = ~/S2Arm/games/<ID>/image/ios/pack   (read-only input)
```

The export runs `push_pack.plan(full=True)` and `push_pack.send()` against a local-directory
"device", so the batching, the tar format and the order are the same code a first USB
install uses. It refuses to write into a non-empty `<out_dir>`. On APFS, large images are
cloned with `cp -c`, so they take no extra space.

`<out_dir>` layout (upload it as-is):

```
<out_dir>/
  ota.json
  img/romfs.img            direct-write images (not tarred), if the pack has any
  tars/<time>_<seq>.tar    <=1 GB pax tar batches (a single file over 1 GB gets its own batch)
  index.tsv
  manifest.json
```

`ota.json`:

```json
{"format": "s2arm-ota", "version": 1, "title_id": "<ID>", "index_sha256": "...",
 "total": 6634950000, "clear_applied": true,
 "files": [{"name": "img/romfs.img", "dest": "romfs.img", "size": 1, "sha256": "...", "order": 0},
           {"name": "tars/1731100000_000.tar", "dest": ".incoming/1731100000_000.tar", ...},
           {"name": "index.tsv", "dest": "index.tsv", ...},
           {"name": "manifest.json", "dest": "manifest.json", ...}]}
```

- `name` is the URL path relative to the directory holding `ota.json`.
- `dest` is where the file goes on the device, relative to `Documents/games/<ID>/资源包/`.
- `order` is the push order: direct images, then tars, then `index.tsv`, then `manifest.json`.
  The manifest comes last because the gate treats the transfer as finished once it sees it.
- `clear_applied`: the device empties `资源包/.applied` before it writes a direct image,
  the same as `push_pack.send()` does.

## 2. Server layout

Any static HTTPS host works. It must answer `Range: bytes=a-b` with `206` and a
`Content-Range` header (nginx, Caddy, S3/R2 and Cloudflare all do). A plain `200` is also
accepted, but only if the body is the whole file. Only `https://` URLs are allowed.

```
https://host/ota/catalog.json
https://host/ota/<ID>/ota.json        <- one export directory per game
https://host/ota/<ID>/tars/...
```

`catalog.json` lists the games:

```json
{"version": 1,
 "headers": {"X-Blazing-Key": "<secret>"},
 "games": [{"id": "01006BB00C6F0000", "name": "Game name", "base": "01006BB00C6F0000/"}]}
```

- `base` can be absolute or relative to the catalog URL. `games` can also be an object
  keyed by title id.
- `headers` (top level, or per game) are sent with every request for `ota.json` and pack
  files. They go only to the host in `base`.
- If the catalog has no `headers`, the app sends the `key` from the open-URL (below) as
  `X-Blazing-Key`. That key is also sent when fetching the catalog itself.
- Nothing secret is compiled into the app. The catalog URL lives in `NSUserDefaults`, and
  the downloaded catalog is cached in `Library/Application Support/S2ArmOTA/`, which is not
  visible in the Files app.

## 3. On the device

- **Configure:** either type the catalog link in Settings → S2Arm → Wireless Download → Catalog URL,
  or open `s2arm://download?catalog=<url-encoded https url>[&key=<value>][&game=<ID>]`.
  You can open that link from Safari, Notes, a QR code, or the private web page. With
  `game`, the download starts straight away. Without it, the app lists the catalog games
  that are not on the device yet. Links are only handled while the game library is showing.
- **Download:** in the library, tapping a game that needs game data opens the help alert.
  When the catalog lists that game, the alert has a **Download** button.
- **What happens:**
  1. The app re-fetches the catalog, then fetches `<base>/ota.json` and validates it: format,
     title id, safe relative paths, tar destinations under `.incoming/`, and index then
     manifest last.
  2. It refuses to start if free space is less than the remaining bytes + 2 GB.
  3. Files download in order into `Documents/games/<ID>/.ota/<n>.part`. Each request is a
     `Range` of up to 256 MB, sent on a background `NSURLSession`. If the app is suspended,
     iOS keeps downloading and relaunches it to queue the next chunk.
  4. When a file is complete, its sha256 is checked. Only then is it renamed into
     `资源包/<dest>`. On a mismatch the file is downloaded again, up to 3 times. The gate
     therefore never sees a half-written tar.
  5. The screen's auto-lock is off while downloading. The progress page uses the same
     look as `notice.m` and has Pause and Hide buttons.
  6. When everything is in place, `.ota/` is removed and the library refreshes. Tapping
     Play then runs the normal import gate: it unpacks the tars, verifies `index.tsv` and
     writes `.applied`.
- **Resume:** progress is saved in `Library/Application Support/S2ArmOTA/job.json`, along
  with the `.part` files. After a pause, a failure or an app kill, tapping Download again
  continues from the current `.part` length. If the server's `ota.json` has changed in the
  meantime (different file list or `index_sha256`), it starts over.

## Limits / not done

- Only for first installs. Every export is a full pack: there is no delta against
  `index.applied.tsv` like the USB push does.
- Download is offered from the container library only. The single-game app's gate page
  (`s2a_ios_show_pack_help`) has no Download button.
- When a chunk fails, the bytes of that chunk (up to 256 MB) are fetched again. System
  `resumeData` is not used.
- The `key` from the open-URL is stored in `NSUserDefaults`, not the Keychain.
