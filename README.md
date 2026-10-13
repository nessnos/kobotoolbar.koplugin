# Kobo-style toolbar for KOReader

A reading toolbar that looks and works like the one on Kobo e-readers. Made to go
with **KoboUI**, but it works on its own too.

Tap the middle of the page (or the top, or the bottom) while reading:

```
22:26                      ─                        ⌔  ▭
←  Back to Home                   ☼   Aa   ılı   ⚙   •••
──────────────────────────────────────────────────────────
                  (your page stays visible)
──────────────────────────────────────────────────────────
                     PAGE 336 OF 1006
|<   ━━━━━━━━━━◎──────────────────────────────────   >|
☰  Chapter Twelve                                  🗎   ⌕
```

Tap the page again to close it. Swipes are left alone: swiping down from the top
still opens KOReader's menu (also while the toolbar is open).

## What each part does

| Part | Tap it to… |
|---|---|
| Status bar (clock, Wi-Fi when on, battery) | open KOReader's menu |
| ← Back to Home / My Books | go back where you opened the book from |
| ☼ | Kobo's Light panel (with KoboUI), or KOReader's frontlight dialog |
| Aa | KOReader's font & layout panel |
| ılı | Kobo's stats panel under the toolbar: this chapter (% read, time left), next chapter (time to read), this book (chapter chart, time left). Tap < > or swipe it for "Last 7 days". Tap ılı again to hide it; long-press ılı for KOReader's book statistics. Times use the Reading statistics plugin (pages without it). |
| ⚙ | KOReader's menu |
| ••• | a menu of actions you choose (bookmark, go to page, book details…) |
| PAGE X OF Y | switch: page / pages left in chapter / time left in chapter / time left in book / % read |
| slider, \|< >\| | skim through the book, jump to the previous / next chapter |
| RETURN TO PAGE N | appears after skimming; goes back where you were |
| ☰ Chapter name | table of contents |
| 🗎 | bookmarks & notes |
| ⌕ | search the book |

## Settings

Gear tab → **Kobo-style toolbar** (also in the ••• menu → Toolbar Settings):

- what opens the toolbar: middle of the page (narrow / medium / wide area), top, bottom;
- **Back button goes to**: automatic (Home or My Books, wherever you opened the
  book from), always Home, or always My Books;
- **Toolbar buttons**: hide any of ☼ Aa ılı ⚙ •••, move them, or add your own
  buttons (name, icon, any KOReader action);
- **••• menu**: pick its actions and their order;
- show battery percentage (Kobo doesn't), show the Wi-Fi icon;
- what the page line shows, chapter marks on the slider.

## Fonts

Everything is sans-serif: with KoboUI installed, the toolbar uses the **Label Font**
you chose in KoboUI (Settings → Style → Label Font), so it matches Home and My
Books; without KoboUI, KOReader's own UI font (Noto Sans by default). "Back to …"
and the chapter name use the font's bold file, or KOReader's bold rendering when
the font has none. "Aa" is drawn as an icon, in a serif, as on Kobo.

## Install

Copy the `kobotoolbar.koplugin` folder into `koreader/plugins/` and restart KOReader.

## Files

- `main.lua` — tap zones, settings, "where was the book opened from", back button
- `kobotoolbar_widget.lua` — the overlay, the ••• drop-down
- `kobotoolbar_iconpicker.lua` — icon grid for custom buttons
- `kobotoolbar_fonts.lua` — font choice
- `icons/` — the toolbar icons; `icons/line/` — icons for custom buttons
