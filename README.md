# Capture

A menu bar app for the whole Mac: screenshots, scrolling captures, screen recordings and voice thoughts. Every capture goes on the clipboard and into
one library folder. Several in a row paste one Cmd+V at a time. It runs on its own and opens at login.

## Use

- **Menu bar icon:** click for the panel (tools, paste queue, library, walkthroughs). Right-click for Settings and Quit. While recording, the icon shows the
  time in red; click it to be asked "Stop recording?" (the record shortcut again asks too; Esc asks; the Stop button in the panel stops at once). Return is left to the app being recorded.
- **Shortcuts:** Settings ▸ "Use the Mac's screenshot keys" (on since 2026-11-22) turns macOS's ⇧⌘3/4/5 off and gives Capture: ⇧⌘4 screenshot,
  ⇧⌘3 whole screen, ⇧⌘5 record, ⇧⌘6 scrolling, ⇧⌘2 voice, ⌃⇧⌘C open Capture. Off, the keys go back to macOS and Capture uses ⌃⇧⌘S, ⌃⇧⌘L, ⌃⇧⌘R, ⌃⌘R.
  Any shortcut can be changed in Settings. `~/Library/Logs/Capture.log` lists what registered and what was pressed.
- **Paste queue tiles:** click one to paste it next, × takes it out, double-click opens it, drag it into any app.
- **Copy several:** click the pictures in the order you want, then Copy. ⌘V in Teams, Mail or Finder pastes all of them. In a terminal or Claude Code,
  Ctrl+V pastes one and brings the next forward; after the last, the whole set is back on the clipboard. (Needs Input Monitoring to see Ctrl+V.)
  Dropping pictures or recordings on the menu bar icon adds them to the paste queue.
- **Paste queue:** take three screenshots, then Cmd+V three times (Ctrl+V in Claude Code). A count rides by the pointer while two or more wait.
  Copying anything else lets the queue go; so does the time set in Settings (15 seconds to 30 minutes, or never; 10 minutes by default).
- **macOS screenshots:** ⇧⌘3/4/5 captures are also copied and moved off the Desktop into the library. Settings ▸ "Send to library" saves them there
  directly, with no floating thumbnail ("Put back" undoes it).
- **Mark up:** double-click a screenshot (panel or paste queue), the pencil on a selection, or ⌃⇧⌘M for the latest. One key per tool:
  V select, A arrow, R box, O ellipse, T text, N numbered pin, H highlight, F focus (dims the rest), B redact (pixelates), M measure (pt), C crop.
  Boxes and ellipses also take a solid or dashed outline and no, transparent or solid fill (shown in the toolbar while one is in hand or selected).
  1–6 colors, [ and ] size, Shift keeps lines level and boxes square, ⌘Z, ⌘D, arrows nudge. Tools stay in hand; a click on a mark selects it.
  Pins get notes at the side: Copy notes gives a numbered list for Jira or Teams; "Print notes under the picture" adds them to the image.
  Done (⌘↩) saves, copies and closes; closing also saves. The library file becomes the marked-up picture; the original and the marks are kept in
  `.markup/` beside it, so reopening keeps every mark editable and Revert to original undoes it all. Redaction is in the saved picture only: the
  original in `.markup/` still holds what was hidden (it is deleted with the capture). Settings ▸ "Mark up each screenshot" opens every new one.
- **Library:** `~/Pictures/Capture`, plain files. Click to select (the number is the paste order), double-click to open, drag out. Copy,
  Show in Finder, Pin, Move to Trash. Optional cleanup after 7/30/90 days; pinned captures are kept.
- **Walkthroughs:** screen-recorded demos kept under `~/Movies` (an `.mp4` with an `.srt` beside it; set `CAPTURE_VIDEO_ROOT` to use another folder). Play, Short cut, Copy, Share, Show in Finder.
- **Chrome full pages:** Settings ▸ Chrome full pages ▸ Set up, then load the shown folder as an unpacked extension. Its button (⌃⇧P) saves the
  whole page exactly, through Chrome's own full-page screenshot.
- **Links for other tools:** `capture://screenshot`, `scrolling`, `record`, `voice`, `markup` (latest screenshot), `panel`, `walkthroughs`.

## Permissions (asked when first needed)

| Permission | For | Without it |
|---|---|---|
| Screen Recording | every screenshot and recording | nothing can be captured |
| Input Monitoring | noticing a paste, for the paste queue | the newest capture is always on the clipboard; Copy still puts every chosen picture on the clipboard, but Ctrl+V cannot step through them |
| Accessibility | a scrolling capture scrolling for you | you scroll by hand while it captures |
| Microphone, Speech Recognition | voice thoughts, voice in recordings | no voice |

## Appearance

Follows the Mac's light or dark setting through DesignKit (`Vendor/DesignKit`, a native SwiftUI port of the Intent design system; see its `NOTICE`). `./test.sh pictures` with
`CAPTURE_SHOTS` draws every screen in both.

## Build and test

```
./build.sh            # build/Capture.app, signed with your Apple Development identity if you have one, otherwise ad hoc (macOS then asks for permissions again after every rebuild)
./build.sh install    # also copies it to ~/Applications and opens it
./test.sh             # core tests, then the real app hidden (throwaway library and pasteboard; nothing on screen)
CAPTURE_SHOTS=/some/dir ./test.sh pictures   # also draws the panel, Settings and bars to PNGs for a look
```

`Sources/CaptureCore` holds what is tested without a screen: stitching (`Stitcher`), the paste queue, the library, shortcuts and Chrome's message
format. `Sources/Capture` is the app; the capture picker, bar and recorder are in there too.

## Requirements

Apple silicon, macOS 15 or later, and Xcode's command line tools (Swift 6). Nothing else to install: Capture uses only Apple frameworks, and the one
bundled dependency (DesignKit) is vendored in this repo. It makes no network requests; everything stays on the Mac.

Built apps are not notarized. If macOS blocks a copy you were given, use System Settings ▸ Privacy & Security ▸ Open Anyway.

## License

MIT (see `LICENSE`). DesignKit is a port of the Intent design system, Apache-2.0 (see `Vendor/DesignKit/NOTICE`). The bundled Inter font is under the
SIL Open Font License 1.1 (`Resources/Fonts/LICENSE-Inter.txt`).
