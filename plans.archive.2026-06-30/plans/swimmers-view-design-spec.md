# I8 SwimmersView Design Spec — Native SwiftUI

**Chunk:** I8 (swimmers tab — list + detail + add/edit)
**Date:** 2026-05-18
**Status:** Draft — pending user review
**Source:** RN `app/(tabs)/swimmers.tsx` (list), `app/swimmers/[id].tsx` (detail), `app/swimmer-sheet.tsx` (add/edit sheet)

---

## 1. Screen Identity

Three screens:

- **SwimmersListView** — `TabView` item 2. Roster home with group sections, filter pills (Active / Archived), inline add-group row, + Add Swimmer entry point.
- **SwimmerDetailView** — pushed from list row. Single swimmer profile with PB management and group toggling.
- **SwimmerSheetView** — `.sheet()` for add/edit. Pre-fills on edit from detail view's Edit button.

---

## 2. Visual Design

### Color Palette (Swift equivalents from `lib/theme.ts`)

| Role         | Hex       | Usage                         |
| ------------ | --------- | ----------------------------- |
| Background   | `#060e18` | Page background               |
| Surface      | `#0d1b2a` | Cards, elevated surfaces      |
| Elevated     | `#1a2d42` | Input fields, interactive     |
| Border       | `#2d3e50` | Dividers, card borders        |
| Text primary | `#e2f4fa` | Headings, primary content     |
| Text muted   | `#7a9bb0` | Secondary labels, hints       |
| Text dim     | `#4a6572` | Timestamps, metadata          |
| Cyan accent  | `#09d4ee` | CTAs, initials, active states |
| Amber        | `#f59e0b` | AM/PM badge, intensity        |
| Danger red   | `#ef4444` | Archive/delete actions        |

### Typography

| Element         | Font    | Size | Weight   |
| --------------- | ------- | ---- | -------- |
| Screen label    | System  | 10pt | Semibold |
| Group header    | System  | 11pt | Semibold |
| Swimmer name    | System  | 17pt | Medium   |
| Initials circle | System  | 16pt | Semibold |
| Button text     | System  | 16pt | Semibold |
| Section label   | System  | 11pt | Semibold |
| PB time         | SF Mono | 16pt | Medium   |

---

## 3. Layout Structure

### SwimmersListView

```
┌─────────────────────────────────────┐
│  SWIMMERS              [+ Add]     │  ← nav bar: label + add button
│  [+ Group]                           │  ← add group button (text, dim)
├─────────────────────────────────────┤
│  [Active]  [Archived]               │  ← filter pills
├─────────────────────────────────────┤
│  GOLD                    3          │  ← group header + count
│  ┌──────────────────────────────┐   │
│  │ (AB) Alex Brown         ›   │   │  ← initials circle + name + chevron
│  │ (JK) Jake Kim           ›   │   │
│  │ (MS) Maria Santos      ›   │   │
│  └──────────────────────────────┘   │
│                                     │
│  SILVER                   2          │
│  ┌──────────────────────────────┐   │
│  │ (DW) Dana White         ›   │   │
│  │ (TZ) Tom Zhang          ›   │   │
│  └──────────────────────────────┘   │
│                                     │
│  NO GROUP                 1          │
│  ┌──────────────────────────────┐   │
│  │ (RB) Ryan Black          ›   │   │
│  └──────────────────────────────┘   │
└─────────────────────────────────────┘
```

**Add Group inline row** (appears when "Add Group" tapped):

```
┌─────────────────────────────────────┐
│  [________________]  [Create]  Cancel │  ← TextField + buttons
└─────────────────────────────────────┘
```

**SwimmerRow anatomy:**

```
┌──────────────────────────────────────┐
│ (AB)  Alex Brown               ›    │  ← initials circle (44pt) + name + chevron
└──────────────────────────────────────┘
```

- Initials circle: 44×44pt, rounded, elevated background, cyan initials
- Long-press: delete confirmation alert
- Swipe left: archive action (amber)

**Empty state:**

```
┌─────────────────────────────────────┐
│                                     │
│  👤 No swimmers yet.                │  ← SF Symbol (person.fill) at 48pt
│                                     │
│  Tap + Add to add your first swimmer │
│                                     │
└─────────────────────────────────────┘
```

---

## 4. SwimmerDetailView

```
┌─────────────────────────────────────┐
│  ← Swimmers                         │  ← nav bar back
├─────────────────────────────────────┤
│  (AB)                        [Edit] │  ← initials circle (56pt) + Edit button
│                                     │
│  Alex Brown                         │  ← 28pt semibold name
│  DOB: Jan 15, 2012  ·  13 years    │  ← 13pt muted (if birthdate known)
│  Form Stroke: [Free▾]               │  ← tappable stroke picker
│  Notes: ...                         │  ← 13pt muted (if present)
├─────────────────────────────────────┤
│  GROUPS                             │  ← section label
│  [Gold ✓] [Silver] [Bronze]         │  ← toggle chips
│  [+ Add to group]                   │  ← if groups exist, else inline create
├─────────────────────────────────────┤
│  PERSONAL BESTS              [+ Add]│  ← section label + add button
│  ┌────────────────────────────┐    │
│  │ 100m Free        1:03.45  │    │  ← PB row: distance+stroke | time
│  │ 50m  Breast         38.20  │    │
│  │ 100m Breast       1:18.90  │    │
│  └────────────────────────────┘    │
│  (long-press PB → delete)           │
├─────────────────────────────────────┤
│  [     Archive Swimmer       ]      │  ← surface amber button
│  [     Delete Swimmer        ]      │  ← danger surface button
└─────────────────────────────────────┘
```

**Header:** 56×56pt initials circle (larger than list row), Edit nav button.
**Form Stroke:** Tappable row showing current stroke → picker sheet with Free/Back/Breast/Fly options.
**Groups:** Toggle chips — tap to add/remove. "+ Add to group" inline if no groups exist (create group sheet).
**PBs:** List rows with distance+stroke on left, time in mono on right. "+ Add" → PB add sheet.
**Archive button:** Amber surface button, calls `SwimmerService.archiveSwimmer()` → pop to list with success toast.
**Delete button:** Danger surface, confirmation alert → hard delete.

---

## 5. SwimmerSheetView (Add/Edit)

```
┌─────────────────────────────────────┐
│  ← Add Swimmer         [Cancel]   [Save] │  ← nav bar: title + cancel + save
├─────────────────────────────────────┤
│                                     │
│  FIRST NAME *                       │  ← label, 11pt dim
│  ┌─────────────────────────────┐   │
│  │ Alex                       │   │  ← TextField, auto-focus on appear
│  └─────────────────────────────┘   │
│                                     │
│  LAST NAME                          │
│  ┌─────────────────────────────┐   │
│  │ Brown                       │   │
│  └─────────────────────────────┘   │
│                                     │
│  BIRTHDATE                          │
│  ┌─────────────────────────────┐   │
│  │ January 15, 2012          ▼ │   │  ← tappable row → DatePicker sheet
│  └─────────────────────────────┘   │
│                                     │
│  GENDER                             │
│  [  M  ] [  F  ] [  —  ]           │  ← segmented control
│                                     │
│  NOTES                              │
│  ┌─────────────────────────────┐   │
│  │                             │   │  ← multiline TextEditor
│  │                             │   │
│  └─────────────────────────────┘   │
│                                     │
└─────────────────────────────────────┘
```

**Presented as:** `.sheet()` — same pattern as SetScheduleView from I7.
**Pre-fill on edit:** Fetch swimmer by `swimmerId` param on `.task`.
**Validation:** First name required. Save button disabled until `firstName.trim().count > 0`.
**DatePicker:** `.datePickerStyle(.graphical)` in a separate sheet (iOS convention), max date = today.
**Save behavior:** Insert new swimmer or update existing. On success, dismiss sheet.

---

## 6. Navigation Flow

```
SwimmersListView
  └── Tap row → SwimmerDetailView (push)
        └── Edit button → SwimmerSheetView (sheet — edit mode, pre-fill)
  └── + Add → SwimmerSheetView (sheet — add mode)
  └── + Group → inline TextField row (create → refresh list)
  └── Long-press row → Delete confirmation alert
  └── Swipe left → Archive action

SwimmerDetailView
  └── Edit → SwimmerSheetView (sheet)
  └── Form Stroke → picker sheet
  └── PB + Add → PBAddSheet (sheet)
  └── PB long-press → Delete confirmation
  └── Archive button → confirm → archive → pop to list
  └── Delete button → confirm → delete → pop to list
```

---

## 7. Component Inventory

### `SwimmersListView`

| Element         | Spec                                                                                 |
| --------------- | ------------------------------------------------------------------------------------ |
| Nav bar         | "SWIMMERS" label + "+ Add" trailing button                                           |
| Filter pills    | "Active" / "Archived" — active = cyan fill, archived = surface+border                |
| Group header    | Uppercase, dim, 11pt semibold + count right-aligned                                  |
| SwimmerRow      | 44pt initials circle + name + chevron; swipe-to-archive (amber); long-press → delete |
| Add Group row   | Inline TextField + Create + Cancel buttons, appears on tap                           |
| Empty state     | Person SF Symbol icon + "No swimmers yet." + "+ Add your first swimmer" link         |
| Pull-to-refresh | `.refreshable { await loadSwimmers() }`                                              |

### `SwimmerDetailView`

| Element         | Spec                                                            |
| --------------- | --------------------------------------------------------------- | --------------------------- |
| Initials circle | 56pt, cyan initials, elevated bg, border                        |
| Edit button     | Nav bar trailing, text button                                   |
| Name            | 28pt semibold, tappable → inline edit (TextField + Save/Cancel) |
| DOB + age       | 13pt muted, only shown if birthdate present                     |
| Form stroke row | Tappable → picker sheet: Free, Back, Breast, Fly                |
| Groups section  | Toggle chips, "+ Add to group" if no groups yet                 |
| PBs section     | List rows (distance+stroke                                      | time), "+ Add" → PBAddSheet |
| Archive button  | Full-width surface, amber border+text                           |
| Delete button   | Full-width danger surface                                       |

### `SwimmerSheetView`

| Element          | Spec                                                   |
| ---------------- | ------------------------------------------------------ |
| Nav bar          | Title ("Add Swimmer" / "Edit Swimmer") + Cancel + Save |
| First name field | Required, TextField, auto-focus                        |
| Last name field  | Optional, TextField                                    |
| Birthdate row    | Tappable → DatePicker sheet, max today                 |
| Gender segmented | M / F / — (—"X" in schema)                             |
| Notes field      | TextEditor, multiline, 80pt min height                 |
| Save button      | Disabled when first name empty                         |

### `PBAddSheet`

```
┌─────────────────────────────────────┐
│  ─────────── ───────────           │  ← grabber
│  Add Personal Best                  │
│                                     │
│  STROKE                             │
│  [Free] [Back] [Breast] [Fly] [IM] │  ← toggle pills
│                                     │
│  DISTANCE                           │
│  [25] [50] [100] [200] [400]       │
│  [800] [1500]                       │
│                                     │
│  TIME (seconds or m:ss.t)           │
│  ┌─────────────────────────────┐   │
│  │                         1:03 │   │  ← large monospace input, 28pt
│  └─────────────────────────────┘   │
│                                     │
│  [         Save PB            ]    │  ← cyan CTA, disabled until complete
└─────────────────────────────────────┘
```

---

## 8. State & Data Flow

### `SwimmersListViewModel`

```swift
@MainActor
final class SwimmersListViewModel: ObservableObject {
    @Published var swimmers: [Swimmer] = []
    @Published var groups: [CoachGroup] = []
    @Published var selectedFilter: SwimmerFilter = .active  // .active | .archived
    @Published var isLoading: Bool = false
    @Published var showAddGroupRow: Bool = false

    func loadSwimmers(coachId: String?) async
    func createGroup(coachId: String?, name: String) async
    func deleteGroup(id: String) async
    func archiveSwimmer(id: String) async
    func deleteSwimmer(id: String) async
}
```

**Filter behavior:**

- `.active` (default): fetch swimmers where `archived_at IS NULL`, sorted by firstName
- `.archived`: fetch swimmers where `archived_at IS NOT NULL`

**Group sorting:** Groups sorted alphabetically. "No group" section always last.

### `SwimmerDetailViewModel`

```swift
@MainActor
final class SwimmerDetailViewModel: ObservableObject {
    @Published var swimmer: Swimmer?
    @Published var groups: [CoachGroup] = []
    @Published var allGroups: [CoachGroup] = []   // coach's groups for toggle display
    @Published var personalBests: [SwimmerPB] = []
    @Published var isLoading: Bool = true

    func loadSwimmer(swimmerId: String) async
    func updateName(firstName: String, lastName: String?) async
    func updateFormStroke(stroke: String) async
    func toggleGroup(groupId: String) async      // add or remove membership
    func archiveSwimmer() async
    func deleteSwimmer() async
}
```

### `SwimmerSheetViewModel`

```swift
@MainActor
final class SwimmerSheetViewModel: ObservableObject {
    @Published var firstName: String = ""
    @Published var lastName: String = ""
    @Published var birthdate: Date = Date()
    @Published var gender: Gender = .unspecified   // M / F / X (X = unspecified)
    @Published var notes: String = ""

    var isEdit: Bool = false
    var swimmerId: String?

    func loadSwimmer(id: String) async            // pre-fill for edit
    func saveSwimmer(coachId: String?) async -> Bool  // returns success
}
```

---

## 9. Interactions

| Interaction             | Behavior                                               |
| ----------------------- | ------------------------------------------------------ |
| Tap swimmer row         | Push `SwimmerDetailView`                               |
| Long-press swimmer row  | Delete confirmation → delete → refresh                 |
| Swipe left on row       | Archive swimmer → refresh                              |
| Tap + Add               | Present `SwimmerSheetView` sheet (add mode)            |
| Tap + Group             | Show inline add-group row                              |
| Create group            | Insert group → refresh list with new group section     |
| Long-press group header | Delete group confirmation → refresh                    |
| Tap Edit (detail)       | Present `SwimmerSheetView` sheet (edit mode, pre-fill) |
| Tap form stroke row     | Present stroke picker sheet → update on select         |
| Tap group chip          | Toggle membership via `SwimmerService`                 |
| Tap PB + Add            | Present `PBAddSheet`                                   |
| Long-press PB row       | Delete PB confirmation → refresh                       |
| Tap Archive             | Amber confirmation → archive → pop to list             |
| Tap Delete              | Danger confirmation → delete → pop to list             |
| Pull-to-refresh list    | Reload swimmers                                        |

---

## 10. File Structure

```
ios-native/Hydrolyze/Sources/
├── Views/
│   ├── Swimmers/
│   │   ├── SwimmersListView.swift     ← I8: roster list with groups
│   │   ├── SwimmerDetailView.swift    ← I8: swimmer profile
│   │   ├── SwimmerSheetView.swift     ← I8: add/edit sheet
│   │   ├── Components/
│   │   │   ├── SwimmerRow.swift       ← I8: list row component
│   │   │   └── PBAddSheet.swift       ← I8: add PB sheet
│   ├── Workouts/                      ← from I6/I7
│   ├── Today/                         ← from I5
│   └── Auth/                          ← from I4
├── ViewModels/
│   ├── SwimmersListViewModel.swift    ← I8
│   ├── SwimmerDetailViewModel.swift   ← I8
│   └── SwimmerSheetViewModel.swift    ← I8
├── Models/                           ← from I3
├── Services/                          ← from I2/I3 (SwimmerService already exists)
└── Lib/
    └── Color+Hex.swift                ← from I4
```

---

## 11. RN Parity / Deliberate Divergence

| RN behavior                                               | Native decision                                  | Reason                                                       |
| --------------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------ |
| Flat list with group sections                             | `List` with `Section` (native grouping)          | SwiftUI `Section` is idiomatic                               |
| Long-press to delete                                      | Swipe-to-archive (amber) + long-press for delete | iOS native: swipe for frequent action, hold for destructive  |
| "Add Swimmer" routes to `/swimmer-sheet` (push)           | `.sheet()` for add/edit                          | Consistent with SetScheduleView (I7) pattern                 |
| Edit on detail page routes to `/swimmer-sheet?id=` (push) | `.sheet()` with pre-fill from param              | Consistent modal pattern                                     |
| Inline name editing                                       | Tappable name → inline TextField (same as RN)    | Preserves detail context                                     |
| Form stroke as segmented row                              | Form stroke as tappable row → picker sheet       | Space-efficient; picker is standard iOS pattern              |
| Group toggle chips                                        | Same — tap chip to toggle membership             | Direct mapping                                               |
| PB modal (stroke/distance/time)                           | `PBAddSheet` as `.sheet()`                       | Consistent with other modal flows                            |
| Delete on detail                                          | Danger button at bottom, confirmation alert      | Clear hierarchy: archive is safe path, delete is last resort |
| No archived filter                                        | "Active" / "Archived" filter pills               | Needed since archive is now a real action                    |

---

## 12. Key Design Decisions

1. **Group sections by CoachGroup** — same as RN. "No group" section last, sorted alphabetically within groups.
2. **Swipe-to-archive over long-press delete** — iOS native gesture. Delete (hard) still available via long-press.
3. **Archived swimmers behind filter toggle** — coaches need to see archived swimmers to un-archive them. Filter pill provides clean UX.
4. **`SwimmerSheetView` as `.sheet()`** — consistent with I7's `SetScheduleView` pattern. Modal sheets for add/edit are standard iOS.
5. **`PBAddSheet` as `.sheet()`** — adds friction intentionally — PB entry is important enough to warrant a dedicated sheet.
6. **Form stroke inline on detail** — shows current value, tap → picker sheet. No picker inline (too much screen real estate).
7. **Initials circle** — 44pt on list row, 56pt on detail header. Consistent with iOS contact patterns.
8. **No age calculation in list** — too much computation per render. Show DOB on detail only.

---

## 13. Tradeoffs Flagged For Eng-Manager

1. **Archive vs. soft-delete**: `SwimmerService.archiveSwimmer()` already exists and sets `archived_at`. This is a soft-delete — times and PBs are preserved. Confirm this is the intended behavior (matching RN's hard delete but with data preserved).
2. **Group deletion**: When a group is deleted (long-press group header), swimmers in that group become "No group" — they don't get deleted. This matches RN behavior.
3. **Age display on detail**: Currently shows "DOB: ... · N years" only if birthdate is present. Age calculated at render time from `birthdate`. This is fine for MVP.
4. **No swimmer search/filter in list**: MVP scope. Alphabetical within group is the only sort.

---

## 14. Out Of Scope

- **Heavy stats/charts on detail view** — ProgressionChart, TrendChart, SpeedCurveChart are later chunks (I11)
- **Last-session indicator on list row** — would require extra query per render; deferred
- **Voice input for swimmer name** — not in I8
- **Bulk archive** — single swimmer only, later chunk if needed

---

_Designer: Hydrolyze Senior Designer_
_Plan absolute path: `/Users/nathanmaxwell/Downloads/Hydrolyze 2/plans/swimmers-view-design-spec.md`_
_Plan relative path: `plans/swimmers-view-design-spec.md`_
