# Fonts

This directory is for custom fonts bundled with the app.

## JetBrains Mono Nerd Font (Phase 2.5-c)

Used for the number components in the live stopwatch (time display, lap
splits, lap numbers). Drop the .ttf files here from the nerd-fonts GitHub
repo: https://github.com/ryanoasis/nerd-fonts (specifically the
JetBrainsMono variants).

Required files (match the Info.plist UIAppFonts array):

- `JetBrainsMonoNerdFont-Regular.ttf`
- `JetBrainsMonoNerdFont-Bold.ttf`

After adding the files:

```bash
cd /Users/nathanmaxwell/Documents/VS\ Code/Hydrolyze\ 2/ios-native
/opt/homebrew/bin/xcodegen generate
```

The fonts are auto-bundled because `Hydrolyze/Resources` is in the
`project.yml` sources list. iOS loads the fonts at app launch via
the UIAppFonts array in Info.plist. The code references them via
`Font.custom("JetBrainsMonoNerdFont-Bold", ...)` and
`Font.custom("JetBrainsMonoNerdFont-Regular", ...)` in
`Hydrolyze/Sources/Views/Timing/TimingView.swift`.

If a font is missing, iOS falls back to the system font — the app
still builds and runs, but the timing screen uses the system monospaced
font instead. No crashes, no broken builds.
