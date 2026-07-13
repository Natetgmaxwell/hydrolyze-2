# I4 LoginView Design Spec — Native SwiftUI
> **[FROZEN 2026-06-30]** Shipped. See source files for current state. Do not edit without checking the working tree first.

**Chunk:** I4 (Supabase auth + login screen)
**Date:** 2026-05-10
**Status:** Approved — ready for Eng-Manager implementation
**Source:** RN `login.tsx` is the reference implementation; this spec adapts it for SwiftUI/iOS conventions.

---

## 1. Screen Identity

**Route:** Root of the app (`/`), shown when unauthenticated.
**Purpose:** Email/password sign-in, account creation, and password reset.

No OAuth providers (Google, Apple) — confirmed by Vision's audit of the RN app. PKCE-protected email/password only.

---

## 2. Visual Design

### Color Palette (from `lib/theme.ts` — use Swift equivalents)

| Role             | Hex       | Usage                                    |
| ---------------- | --------- | ---------------------------------------- |
| Background       | `#060e18` | Page background (`Color(hex: "060e18")`) |
| Surface/elevated | `#1a2d42` | Input field backgrounds                  |
| Border           | `#2d3e50` | Input borders                            |
| Text primary     | `#e2f4fa` | Input text, body                         |
| Text dim         | `#4a6572` | Labels, placeholders                     |
| Text muted       | `#7a9bb0` | Secondary labels                         |
| Cyan accent      | `#09d4ee` | Title, button, active links              |
| Amber            | `#f59e0b` | Error states                             |

### Typography

| Element               | Font                                    | Size | Weight            |
| --------------------- | --------------------------------------- | ---- | ----------------- |
| App title "HYDROLYZE" | `FontFamily.mono` (JetBrains Mono Bold) | 44pt | Bold              |
| Subtitle              | System `Font`                           | 14pt | Regular           |
| Input labels          | System `Font`                           | 10pt | Semibold, tracked |
| Button text           | System `Font`                           | 16pt | Semibold          |
| Link text             | System `Font`                           | 12pt | Regular           |

### Layout

Centered form, vertically aligned. No chrome, no navigation bar — this is the entry point.

```
┌─────────────────────────────────────┐
│                                     │
│           HYDROLYZE                 │  ← cyan, mono, 44pt
│          Coach Dashboard           │  ← muted, 14pt
│                                     │
│         EMAIL                       │  ← dim, 10pt, tracked
│    ┌─────────────────────────┐    │
│    │  coach@team.com          │    │  ← elevated bg, border, 56pt tall
│    └─────────────────────────┘    │
│                                     │
│         PASSWORD                    │
│    ┌─────────────────────────┐    │
│    │  ••••••••               │    │
│    └─────────────────────────┘    │
│                                     │
│    ┌─────────────────────────┐    │  ← cyan fill, 56pt tall
│    │       SIGN IN            │    │
│    └─────────────────────────┘    │
│                                     │
│   New coach? Sign Up   Forgot?     │  ← cyan links, 12pt
│                                     │
└─────────────────────────────────────┘
```

In **Sign Up** mode: title becomes "Create Account", button "Sign Up", footer link "Back to Sign In".
In **Reset** mode: password field hidden, title "Reset Password", button "Send Reset Link".

---

## 3. States

### Sign In (default)

- Email input (keyboard type: `.emailAddress`, autocorrect off, lowercase)
- Password input (secure, no autocorrect)
- "Sign In" primary button
- Footer: "New coach? Sign Up" + "Forgot Password?" links

### Sign Up

- Email input
- Password input (min 6 chars — validate before submit)
- "Sign Up" primary button
- Footer: "Back to Sign In" link
- On success: show alert "Check your email to confirm your account"

### Reset Password

- Email input only
- "Send Reset Link" primary button
- On success: show alert "Check your email for a reset link"
- Footer: "Back to Sign In" link

### Loading

- Button shows `ProgressView()` (native iOS spinner) in cyan-tinted color
- Inputs remain interactive (don't disable — loading is fast)

### Error

- Inline alert (`Alert` or sheet): "Authentication Error: [message]"
- No red borders on fields (keep it simple)

---

## 4. Component Inventory

### `LoginView` (root)

- Hosts the form
- Manages `email`, `password`, `mode` (signIn/signUp/reset), `loading` state
- Calls `AuthService.shared.signIn()` / `signUp()` / `resetPassword()`

### `AuthTextField` (reusable input)

- 56pt tall, `backgroundColor: Color(hex: "1a2d42")`, `cornerRadius: 8`
- 1px border `Color(hex: "2d3e50")`
- Label floats above (not inside the field)
- Placeholder text in `Color(hex: "4a6572")`
- 16px padding horizontal

### `PrimaryButton`

- 56pt tall, full-width
- `Color(hex: "09d4ee")` background, black text
- Corner radius 12
- Shadow: `Color(hex: "09d4ee").opacity(0.3)`, blur 20, offset (0, 0)
- Loading: replace label with `ProgressView()`

### `LinkText`

- 12pt, `Color(hex: "09d4ee")`
- No underline (iOS standard link color)

---

## 5. Navigation On Success

- Sign In success → push to `TodayView` (main coach dashboard — the `today.tsx` equivalent)
- Sign Up success → show confirmation alert, stay on login
- No back navigation from dashboard (auth state persists via `AuthManager`)

---

## 6. Keyboard Handling

- `ScrollView` wrapping form
- `keyboardVerticalOffset` on `NavigationStack` to prevent keyboard from covering fields
- Tap outside to dismiss keyboard

---

## 7. File Structure

```
ios-native/Hydrolyze/Sources/
├── App/
│   └── ContentView.swift       ← update: route to LoginView or main tab
├── Views/
│   └── Login/
│       ├── LoginView.swift     ← main login screen (sign in/up/reset)
│       └── AuthTextField.swift ← reusable input component
└── Services/
    └── AuthService.swift       ← already exists from I2
```

---

## 8. Out Of Scope

- OAuth providers (Google, Apple) — not in the RN app, not adding here
- Biometric auth (Face ID / Touch ID) — future enhancement, not I4
- "Remember me" checkbox — not in RN app

---

## 9. Dependency On SwiftUI Patterns

Eng-Manager should be aware of:

- `NavigationStack` for SwiftUI navigation (no `UINavigationController`)
- `@State` for local form state (`email`, `password`, `loading`, `mode`)
- `@Environment(AuthManager.self)` to read auth state in `ContentView`
- `.alert()` modifier for error/success messages
- `FocusState` for keyboard dismissal

---

_Designer: Hydrolyze Senior Designer_
_Plan relative path: `plans/login-view-design-spec.md`_
