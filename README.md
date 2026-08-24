<div align="center">

<img src="YouFlow/Resources/LogoMark.png" width="128" alt="UFlow">

# UFlow

**Talk to your Mac. Get text where your cursor is.**
On-device, private, and shaped like a boombox from 1994.

[![Download](https://img.shields.io/badge/Download-UFlow%201.0.dmg-CC330D?style=for-the-badge)](https://github.com/Wasik-Yousha/UFlow/releases/latest)
&nbsp;
![macOS](https://img.shields.io/badge/macOS-26%2B-2B2018?style=for-the-badge)
&nbsp;
![On-device](https://img.shields.io/badge/audio-never%20leaves%20your%20Mac-0A444F?style=for-the-badge)

<img src="docs/deck.png" width="820" alt="The UFlow deck: transport, level meter, counter">

</div>

---

## The short version

You're writing an email. You'd rather say it than type it.

**Press `Fn` + `Y`.** A small recorder bar slides up at the bottom of the screen — needle twitching, counter running.

<div align="center">
<img src="docs/hud-dark.png" width="420" alt="The floating recorder bar while dictating">
</div>

**Talk.** Normally. It listens on-device — no server, no account, no upload.

**Press `Fn` + `Y` again.** The bar disappears and your words are typed into the email. Not the clipboard. Not another window. Exactly where your cursor was.

That's the whole app. Everything below is detail.

---

## It learns the words you actually use

Every dictation tool writes **"cloud code"** when you say *Claude Code*. And *Anthropic* comes out as **"anthropic"**, **"entropic"**, or something worse.

So UFlow keeps a dictionary.

<div align="center">
<img src="docs/dictionary.png" width="820" alt="The dictionary tab">
</div>

Two kinds of entry:

| | You add | What happens |
|:--|:--|:--|
| **TERM** | `Anthropic` | The engine is nudged toward it *before* it listens, and the spelling is enforced after. |
| **FIX** | `cloud code → Claude Code` | Whenever it hears the first, it writes the second. |

**Both, because neither is enough alone.** Nudging the engine is a hint, not a promise. The correction pass afterwards is the guarantee.

And it is careful. `Claude Code` catches `cloudcode`, `Cloud-Code` and `CloudCode` — because these models glue words together — but it will **never** touch `Cloudflare`, or the ordinary word `cloud`. Corrections are whole-word, case-insensitive, longest-match-first, in a single pass so rules cannot cascade into each other.

Try to add a plain English word and it warns you first.

When a correction fires, the history shows exactly what changed:

> **CORRECTED**  `claude-code → Claude Code ×2`

The dictionary is a plain text file. Edit it in the app, or in any editor:

```
~/Library/Application Support/UFlow/dictionary.txt
```

```
Anthropic
Claude Code
cloud code => Claude Code
!clawed code => Claude Code      # a leading ! keeps an entry without applying it
```

Switch back to UFlow and it re-reads the file.

---

## Install

**One line. No warnings, no dialogs.**

```sh
curl -fsSL https://raw.githubusercontent.com/Wasik-Yousha/UFlow/main/scripts/install.sh | bash
```

<details>
<summary><b>Why a terminal command is smoother than downloading the .dmg</b></summary>

<br>

macOS attaches a *quarantine flag* to anything a **browser** downloads, and Gatekeeper refuses to open a quarantined app unless Apple has notarized it. Notarization needs a $99/year Apple Developer membership, which this project does not have.

`curl` does not set that flag. So installing this way is not defeating anything — you ran the installer on purpose — it simply skips a warning that exists only because of how the file arrived.

The script checks your macOS version, quits any running copy, installs to `/Applications`, and opens it.

</details>

**Prefer the download button?** Grab the `.dmg`, drag UFlow onto Applications — then open **System Settings ▸ Privacy & Security**, scroll down, and click **Open Anyway**. (Right-click ▸ Open no longer works on recent macOS.) The disk image ships a `Read Me First.txt` saying the same.

### Three permissions

macOS asks for these on first launch. All three are genuinely required:

| Permission | Without it |
|:--|:--|
| **Microphone** | It cannot hear you. |
| **Input Monitoring** | The hotkey will not work from other apps. |
| **Accessibility** | It cannot type the transcript where you were working. |

---

## The window

Two tabs: history, and the dictionary.

<div align="center">
<img src="docs/window-light.png" width="880" alt="UFlow, light">
</div>

Every transcription is searchable, has a copy button, and shows which engine produced it and how long it took. **RECORD** and **STOP** work right there if you would rather not use the hotkey — those go to history instead of being typed anywhere.

Light or dark, switchable in Settings independently of macOS:

<div align="center">
<img src="docs/window-dark.png" width="880" alt="UFlow, dark">
</div>

<details>
<summary><b>Yes, it makes noises</b></summary>

<br>

Eight of them — a latching key going down, a shorter clunk for stop, a detent tick on the tabs, a dull thunk on delete. None are audio files. They are synthesised at launch from a noise burst through a low-pass plus a body tone that drops in pitch as the key seats, which is what a plastic key actually sounds like.

Turn them off in Settings if you would rather work in silence.

</details>

---

## Build it yourself

No certificate needed:

```sh
git clone https://github.com/Wasik-Yousha/UFlow.git && cd UFlow
xcodebuild -project YouFlow.xcodeproj -scheme YouFlow -configuration Release \
           -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY="-" build
cp -R build/DerivedData/Build/Products/Release/UFlow.app /Applications/
```

Or open `YouFlow.xcodeproj` in Xcode, set signing to your own team, and hit Run.

```sh
./scripts/make-dmg.sh      # -> dist/UFlow-1.0.dmg
```

Debug builds carry their own checks:

```sh
UFlow.app/Contents/MacOS/UFlow --self-check   # correction engine + dictionary round-trip
UFlow.app/Contents/MacOS/UFlow --dump-menu    # prints the menu bar
```

---

## Everything visual comes from one file

<div align="center">
<img src="docs/hud-light.png" width="420" alt="The recorder bar in light appearance">
</div>

Colour, type scale, spacing, corner radius, stroke, shadow, motion **and sound** live in [`DesignTokens.swift`](YouFlow/Sources/DesignTokens.swift). Views pull from `Tok.*` — there are no one-off values in components.

The brand palette is sampled from the app icon: vermilion `#D5391B`, teal `#0A444F`, amber `#E88E14`, cream `#FDF1D3`. The chassis and instrument colours are sampled from the design references. Nothing was eyeballed.

`UFlow-Design-Tokens.html` in this repo is a readable sheet of the whole system, including a live VU meter for tuning the needle's attack and release.

<details>
<summary><b>Where things live</b></summary>

<br>

```
YouFlow/Sources/
  DesignTokens.swift          the design system — every visual value
  DictationApp.swift          app entry, scenes, menus
  AppState.swift              session coordinator
  SpeechEngine.swift          Apple Speech + microphone capture
  TranscriptProcessor.swift   the dictionary's correction pass
  Persistence.swift           dictionary, history, settings
  HotkeyManager.swift         global event tap
  ClipboardInjector.swift     text injection
  HUDPanel.swift              the floating recorder bar
  DeckView.swift              the hardware deck
  MainWindowView.swift        window and tabs
  TranscriptionsView.swift    history
  DictionaryView.swift        the dictionary
  SettingsView.swift          hotkey, model, appearance
```

</details>

---

## Honest limitations

- **macOS 26 or later.** UFlow is built on Apple's `SpeechAnalyzer`, which does not exist before macOS 26. Running on older versions needs a completely different transcription engine — that work is tracked in [issue #1](https://github.com/Wasik-Yousha/UFlow/issues/1).
- **English only** right now, because that is the locale the engine is asked for.
- **Not notarized.** See the install section.

---


