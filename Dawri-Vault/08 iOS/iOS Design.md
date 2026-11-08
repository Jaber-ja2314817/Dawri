---
tags: [ios, design, authority]
updated: 2026-11-07
---

# iOS Design (the design authority for the phone app)

Every builder follows this note. It decides what [[iOS Brief]] left open. Where they disagree, the brief wins. Web values come from `frontend/src/index.css`, `ui.tsx`, `PatientShell.tsx` and `ticket.css`. Behaviour comes from `frontend/src/pages/patient/`.

**The idea.** دوري means "my turn". So the one hue in the app lands on one thing only: the patient's own turn, which is their number and their current stage. Everything else is ink on a ledger.

**The face** (taste, `app-screens.md` §2.3). From the style's own list: the blue-grey ground `#f2f4f7`, and the hue on the main data element. The signature element is the ticket block with its stage track. The Arabic wordmark is the product's mark. Figures stay in the text face, because the mono option is not native to iOS.

## 0. What each skill decided

| Area | Decided by | Decision |
| --- | --- | --- |
| Palette and colour budget | `design-taste-frontend`, app-screens §9 | Achromatic ledger: ink chrome, near-black primary, hue on data only, pale pill pairs, true neutral darks stepped by lightness, one ground, no navy |
| Type scale and weights | taste §9.1 for roles and three weights; `apple-design` §15 for Dynamic Type and the system font | Roles from taste, mapped onto Apple text styles |
| Layout | taste §4, §7, §10, §12 | 4 pt scale, 16 pt gutter, one left edge, radius 8/6, 44 pt rows, label over field, numbers on one trailing edge |
| States | taste §11 | Flat still skeleton, error inside the block, grey dash for a missing value, a real zero printed |
| Surfaces | taste §9.4 | 1 pt edge or a tone step, no shadow at rest |
| Motion and springs | `apple-design` §3 to §5 | Springs on everything touched, critically damped by default, from the live value, input never locked |
| Press feedback | `apple-design` §1 and §10 | Respond on touch-down, scale 0.97, commit on touch-up |
| Haptics | `apple-design` §13 | Causality, harmony, utility: few, and fired on the same frame as the visual |
| Accessibility settings | `apple-design` §14 | Reduce Motion gets a cross-fade, never nothing. Reduce Transparency and Increase Contrast respected |
| Wayfinding, agency | `apple-design` §16 | Every screen answers where am I and how do I get out. Confirm only what cannot be undone |

### Conflicts and how they were settled

| Conflict | Taste says | Apple says | Ruling |
| --- | --- | --- | --- |
| Materials | No glass, no blur | Translucent chrome (§12) | System chrome keeps the system material. Nothing of ours is translucent. See section 5 |
| Scroll edge | 1 px borders are fine | Scroll edge effects, not dividers | The nav bar edge is the system's. Cards and rows use our 1 pt edges |
| Depth | No shadow at rest | Depth and shadow by size | Our surfaces have none. System sheets keep theirs |
| Fixed sizes | 12/14/16/24/30 | Dynamic Type | Dynamic Type wins. Sizes become text styles |
| Tracking | -0.02em on display type | Size-specific tracking | Neither by hand. SF applies its own table. Tracking on Arabic breaks the joins, so `.tracking` and `.kerning` are banned |
| Bounce | Nothing performs | 0.8 damping for momentum | Damping 1.0 on every constant. Everything draggable is a system surface with its own spring |
| Loading | Flat bars, no shimmer | Status must be exposed | Flat still bars for content, a spinner inside the acting button |
| Number size | Nothing at 48 or over | None | The S10 number stays the one exception, as in [[Build Decisions]]. The countdown stays at 34 |
| Control edge | `#d4d4d4`, one step stronger than a card | Legible controls | The brief's 3:1 gate wins. `control` moves to `#858585` |
| Centring | Left by default, centre one moment | None | Start-aligned. Centre only the ticket block, the S09 countdown and the footer |

Two changes from the web, both on purpose. The selected map pin is ink, not the hue, because the brief keeps the hue to the patient's own number and current stage. On S06, Call 999 is pinned to the bottom, so it can never scroll away.

## 1. Colour

### 1.1 Tokens

| Token | Light | Dark | Role |
| --- | --- | --- | --- |
| `ground` | `#f2f4f7` | `#101113` | Screen background. Light value is the icon ground |
| `surface` | `#ffffff` | `#1a1b1e` | Cards, fields, assistant bubble, wait badge |
| `raised` | `#eeeeee` | `#26272b` | Pressed and selected fill on a card |
| `skeleton` | `#e3e5e9` | `#2c2d31` | Loading bars, flat and still |
| `hairline` | `#e6e6e6` | `#2c2d31` | Card edge, 1 pt. Decorative |
| `rule` | `#efefef` | `#232428` | Row rule inside a card, 1 pt. Decorative |
| `control` | `#858585` | `#76777c` | Edge of fields and secondary buttons, future-stage ring. Web `#d4d4d4` was 1.5:1, so it moved to `disabledFill` |
| `ink` | `#0a0a0a` | `#f4f4f5` | Titles, body, values, icons, system tint |
| `muted` | `#6b6b6b` | `#a6a7ac` | Labels, hints, footer |
| `primaryFill` | `#0a0a0a` | `#f4f4f5` | Primary button, user bubble, called block, selected wait badge |
| `primaryPressed` | `#2a2a2a` | `#d4d4d8` | Primary button pressed |
| `primaryText` | `#ffffff` | `#0a0a0a` | Text on `primaryFill` |
| `disabledFill` | `#d4d4d4` | `#2c2d31` | Primary button disabled |
| `disabledText` | `#595959` | `#a6a7ac` | Text of any disabled control |
| `hue` | `#1d5fbf` | `#689ce8` | **The one hue.** Own number and current stage, nothing else. Dark value keeps hue 215.6 and saturation 73.6, only lightness moves (43.1 to 65.9) |
| `positive` | `#2e7d32` | `#62c98a` | S11 check mark and done text |
| `negative` | `#c4242a` | `#ff8f87` | Field error, destructive label and edge. Text and thin edges only, never a fill |
| `warning` | `#92400e` | `#e8b06a` | Warning text |
| `pillPositiveFill` | `#dcfae5` | `#16291d` | Pill fill |
| `pillPositiveText` | `#04250e` | `#8fe3ae` | Pill text |
| `pillNegativeFill` | `#ffedea` | `#331b1c` | Pill fill, destructive pressed |
| `pillNegativeText` | `#831c1e` | `#ffb4ad` | Pill text |
| `pillWarningFill` | `#fffbeb` | `#30230f` | Pill fill |
| `pillWarningText` | `#92400e` | `#f2c078` | Pill text |
| `pillNeutralFill` | `#eeeeee` | `#2c2d31` | Pill fill |
| `pillNeutralText` | `#3d3d3d` | `#d9d9dc` | Pill text |
| `noticeFill` | `#fffbeb` | `#2a2012` | Notice block |
| `noticeEdge` | `#fde68a` | `#5c4520` | Notice edge, 1 pt. Decorative |
| `noticeText` | `#92400e` | `#f2c078` | Notice text |
| `emergencyField` | `#c4242a` | `#c4242a` | S06 full field |
| `emergencyText` | `#ffffff` | `#ffffff` | Everything set on the field, footer included |
| `emergencyPressed` | `#a81d23` | `#a81d23` | Language toggle pressed on the field |
| `emergencyCallFill` | `#ffffff` | `#ffffff` | Call 999 button |
| `emergencyCallText` | `#0a0a0a` | `#0a0a0a` | Call 999 label |
| `emergencyCallPressed` | `#eeeeee` | `#eeeeee` | Call 999 pressed |
| `emergencyCard` | `#ffffff` | `#ffffff` | Nearest department card |
| `emergencyCardText` | `#0a0a0a` | `#0a0a0a` | Card text and map link |
| `emergencyCardMuted` | `#6b6b6b` | `#6b6b6b` | Card label |
| `emergencyLink` | `#0a0a0a` | `#0a0a0a` | Map link on the nearest department card. The same as `emergencyCardText` at rest, with its own Increase Contrast value in section 1.3 |

The emergency set is the same in both themes on purpose. S06 must read the same at night, and it must be recognised at once. Its tokens do not depend on the colour scheme. Only Increase Contrast changes them.

Dark is a palette, not an inversion. The ground and surfaces keep the light ground's cool cast at under 9% saturation, so they read as neutral and not navy. Depth is a lightness step. Status colours are lifted, not flipped. `#0a0a0a` text on a near-white primary is the taste skill's inverted button.

Tint: set `AccentColor` in the asset catalog to `ink` (`#0a0a0a` and `#f4f4f5`) and apply `.tint(DS.Color.ink)` at the root. Without this, system controls turn blue, and the hue leaks into chrome.

### 1.2 Contrast

WCAG 2.x: channel `c/255`, then `c/12.92` if at most 0.03928, else `((c+0.055)/1.055)^2.4`. `L = 0.2126R + 0.7152G + 0.0722B`. Ratio `(L1+0.05)/(L2+0.05)`. All ratios below were computed by script, not estimated. IC is Increase Contrast.

| Foreground | Background | Use | Floor | Light | Dark | Light IC | Dark IC |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `ink` | `ground` | Screen title, section, body on the ground | 4.5 | 17.97 | 17.19 | 19.06 | 18.89 |
| `ink` | `surface` | Body and values on a card, assistant bubble, wait badge | 4.5 | 19.80 | 15.67 | 21.00 | 17.22 |
| `ink` | `raised` | Secondary button pressed, selected list row | 4.5 | 17.06 | 13.57 | 16.83 | 13.75 |
| `muted` | `ground` | **Footer text**, hints and captions on the ground | 4.5 | 4.84 | 7.87 | 8.04 | 11.42 |
| `muted` | `surface` | Labels and secondary text on a card | 4.5 | 5.33 | 7.17 | 8.86 | 10.41 |
| `muted` | `raised` | Secondary text on a pressed or selected row | 4.5 | 4.59 | 6.21 | 7.10 | 8.31 |
| `primaryText` | `primaryFill` | Primary button, user bubble, called block, selected badge | 4.5 | 19.80 | 18.01 | 21.00 | 21.00 |
| `primaryText` | `primaryPressed` | Primary button pressed | 4.5 | 14.35 | 13.40 | 14.35 | 14.21 |
| `disabledText` | `disabledFill` | Primary button disabled | 4.5 | 4.73 | 5.73 | 6.49 | 7.32 |
| `disabledText` | `surface` | Secondary button disabled | 4.5 | 7.00 | 7.17 | 10.86 | 11.29 |
| `disabledText` | `raised` | Text field disabled | 4.5 | 6.04 | 6.21 | 8.70 | 9.01 |
| `hue` | `surface` | Own number and current stage label on a card | 4.5 | 6.10 | 6.16 | 8.56 | 8.56 |
| `hue` | `ground` | Same, if a card is ever absent | 4.5 | 5.54 | 6.76 | 7.77 | 9.39 |
| `positive` | `surface` | Done text on a card | 4.5 | 5.13 | 8.40 | 8.04 | 10.94 |
| `positive` | `ground` | S11 check mark on the ground (large glyph) | 3.0 | 4.65 | 9.21 | 7.29 | 12.01 |
| `negative` | `surface` | Destructive label, field error on a card | 4.5 | 5.78 | 7.82 | 7.86 | 10.16 |
| `negative` | `ground` | Field error on the ground | 4.5 | 5.25 | 8.57 | 7.13 | 11.14 |
| `negative` | `pillNegativeFill` | Destructive button pressed | 4.5 | 5.11 | 7.25 | 6.94 | 9.42 |
| `warning` | `surface` | Unsent note on the summary card | 4.5 | 7.09 | 8.90 | 8.97 | 10.32 |
| `warning` | `ground` | Warning text on the ground | 4.5 | 6.43 | 9.76 | 8.14 | 11.32 |
| `pillPositiveText` | `pillPositiveFill` | Pill, positive | 4.5 | 14.77 | 10.06 | 14.77 | 11.88 |
| `pillNegativeText` | `pillNegativeFill` | Pill, negative | 4.5 | 8.63 | 9.42 | 10.45 | 11.52 |
| `pillWarningText` | `pillWarningFill` | Pill, warning | 4.5 | 6.84 | 9.17 | 8.65 | 11.00 |
| `pillNeutralText` | `pillNeutralFill` | Pill, neutral | 4.5 | 9.36 | 9.76 | 11.50 | 11.17 |
| `noticeText` | `noticeFill` | Notice | 4.5 | 6.84 | 9.58 | 8.65 | 11.50 |
| `primaryFill` | `ground` | Primary button edge against the ground | 3.0 | 17.97 | 17.19 | 19.06 | 18.89 |
| `primaryFill` | `surface` | Primary button edge against a card | 3.0 | 19.80 | 15.67 | 21.00 | 17.22 |
| `control` | `surface` | Field and secondary button edge on a card | 3.0 | 3.69 | 3.85 | 5.74 | 6.21 |
| `control` | `ground` | Field and secondary button edge on the ground | 3.0 | 3.35 | 4.23 | 5.21 | 6.81 |
| `control` | `raised` | Future-stage ring and field edge on raised | 3.0 | 3.18 | 3.34 | 4.60 | 4.96 |
| `hue` | `surface` | Current-stage dot on a card | 3.0 | 6.10 | 6.16 | 8.56 | 8.56 |
| `negative` | `surface` | Error field edge, destructive edge | 3.0 | 5.78 | 7.82 | 7.86 | 10.16 |

Emergency:

| Foreground | Background | Use | Floor | Both themes | Increase Contrast |
| --- | --- | --- | --- | --- | --- |
| `emergencyText` | `emergencyField` | Title, reply, **footer**, override, language label on the field | 4.5 | 5.78 | 7.33 |
| `emergencyText` | `emergencyPressed` | Language toggle pressed on the field | 4.5 | 7.33 | 9.10 |
| `emergencyCallText` | `emergencyCallFill` | Call 999 label | 4.5 | 19.80 | 21.00 |
| `emergencyCallText` | `emergencyCallPressed` | Call 999 pressed | 4.5 | 17.06 | 16.83 |
| `emergencyCallFill` | `emergencyField` | Call 999 edge against the field | 3.0 | 5.78 | 7.33 |
| `emergencyCardText` | `emergencyCard` | Nearest department card text | 4.5 | 19.80 | 21.00 |
| `emergencyCardMuted` | `emergencyCard` | Nearest department card label | 4.5 | 5.33 | 8.86 |

Not checked, because they carry no meaning alone: `hairline`, `rule`, `noticeEdge` and `skeleton`. Surface on ground is 1.10:1 in both themes. The edge, not the ratio, is what separates a card.

A `DesignContrastTests` suite in DawriCore reads the same hex table and fails below these floors, so a later edit cannot drift.

### 1.3 Increase Contrast values

Only tokens that change. `ground` and `surface` stay. Load through `UIColor` dynamic providers that read `userInterfaceStyle` and `accessibilityContrast`.

| Token | Light | Dark |
| --- | --- | --- |
| `raised` | `#e6e6e6` | `#2c2d31` |
| `skeleton` | `#d4d6da` | `#3a3b40` |
| `hairline` | `#a3a3a3` | `#56575c` |
| `rule` | `#c4c4c4` | `#3f4045` |
| `control` | `#666666` | `#9a9ba0` |
| `ink` | `#000000` | `#ffffff` |
| `muted` | `#4a4a4a` | `#c8c9cd` |
| `primaryFill` | `#000000` | `#ffffff` |
| `primaryText` | `#ffffff` | `#000000` |
| `disabledFill` | `#c8c8c8` | `#3a3b40` |
| `disabledText` | `#3d3d3d` | `#d0d1d5` |
| `hue` | `#164a96` | `#91b9f3` |
| `positive` | `#1f5c23` | `#8ae0ad` |
| `negative` | `#a01b20` | `#ffb4ad` |
| `warning` | `#7a350b` | `#f2c078` |
| `pillPositiveText` | `#04250e` | `#b4f0ca` |
| `pillNegativeText` | `#6e1416` | `#ffd0cb` |
| `pillWarningText` | `#7a350b` | `#f7d6a3` |
| `pillNeutralFill` | `#e6e6e6` | `#3a3b40` |
| `pillNeutralText` | `#2a2a2a` | `#ffffff` |
| `noticeEdge` | `#b98a1e` | `#8a6a30` |
| `noticeText` | `#7a350b` | `#f7d6a3` |
| `emergencyField` | `#a81d23` | `#a81d23` |
| `emergencyPressed` | `#8f171c` | `#8f171c` |
| `emergencyCardText` | `#000000` | `#000000` |
| `emergencyCardMuted` | `#4a4a4a` | `#4a4a4a` |
| `emergencyCallPressed` | `#e6e6e6` | `#e6e6e6` |
| `emergencyCallText` | `#000000` | `#000000` |
| `emergencyLink` | `#000000` | `#000000` |

## 2. Type

SF Pro and SF Arabic come through `.font(.body)` and friends, never by name. No custom fonts. Three weights only: regular, medium, semibold.

| Role | `DS.TextRole` | SwiftUI style | Weight | Default pt | AX3 pt, about | Digits |
| --- | --- | --- | --- | --- | --- | --- |
| Product name in the bar | `.barTitle` | `.headline` | semibold | 17 | capped by the bar | |
| Screen title | `.screenTitle` | `.title2` | semibold | 22 | 43 | |
| Emergency title | `.emergencyTitle` | `.title` | semibold | 28 | 48 | |
| S01 purpose line | `.lead` | `.title3` | regular | 20 | 43 | |
| Emergency reply, self-harm | `.urgent` | `.title3` | medium | 20 | 43 | |
| Section | `.section` | `.headline` | semibold | 17 | 40 | |
| Body | `.body` | `.body` | regular | 17 | 40 | |
| Body, strong | `.bodyStrong` | `.body` | medium | 17 | 40 | |
| Secondary | `.secondary` | `.subheadline` | regular | 15 | 36 | |
| Secondary, strong | `.secondaryStrong` | `.subheadline` | semibold | 15 | 36 | |
| Label | `.label` | `.subheadline` | medium | 15 | 36 | |
| Caption | `.caption` | `.caption`, Arabic `.footnote` | regular | 12, 13 | 32, 33 | |
| Pill | `.pill` | `.caption`, Arabic `.footnote` | medium | 12, 13 | 32, 33 | mono |
| Button | `.button` | `.body` | semibold | 17 | 40 | mono |
| Call 999 | `.callButton` | `.title3` | semibold | 20 | 43 | mono |
| Stat value | `.statValue` | `.title3` | semibold | 20 | 43 | mono |
| Countdown | `.countdown` | `.largeTitle` | semibold | 34 | 52 | mono |
| Wait badge | `.badge` | `.subheadline` | semibold | 15 | capped at `.xLarge`, 17 | mono |
| Ticket number | `.ticketNumber` | `.system(size: 112, weight: .semibold)` | semibold | 112 cap | fits width | mono |

**Dynamic Type range.** Apply `.dynamicTypeSize(.xSmall ... .accessibility3)` at the root. AX3 is what this app promises and reviews. Three controls cap lower and show the large content viewer with `.accessibilityShowsLargeContentViewer()`: `LanguageToggle` at `.xxxLarge`, `WaitBadge` at `.xLarge`, and the gear at `.xxxLarge`.

As built, two additions. The product name in the bar also carries `.accessibilityShowsLargeContentViewer()`, because the system bar holds it to its own height. And the Dynamic Type audit asks for AX5, so against the AX3 cap it calls every text partly unsupported. A DEBUG-only `-demoTypeCap off` lifts the cap for the audit, so its findings name text that does not scale at all. Release keeps the cap.

**Arabic adjustments.** All live in `dsText(_:)`, which reads the language.

| Rule | Value |
| --- | --- |
| Line spacing, Arabic | `.lineSpacing(2)` on `body`, `bodyStrong`, `secondary`, `caption`, `lead`, `urgent`. `.lineSpacing(3)` on `screenTitle` and `emergencyTitle`. Zero on single-line controls |
| Line spacing, English | Zero. The style's own leading stands |
| Caption | One step up to `.footnote`, because dots and marks collapse at 12 pt |
| Tracking, kerning | Banned in both languages |
| Italic, all caps | Banned |
| Weight | Same as English. SF Arabic holds at semibold |

**`monospacedDigit`** goes on the roles marked mono above. Set it in the `DS.TextRole` font. It also applies to `caption` when a line is a clock or a date in a column, such as `ticket.updatedAt` and S12 dates. Use `.font(role.font.monospacedDigit())` there.

**Latin digits in both languages.** Set the root locale to `Locale(identifier: "ar_QA@numbers=latn;calendar=gregorian")` in Arabic and `en_GB` in English, the same identifiers as `formatDate` in DawriCore. Dates go through `formatDate(_:lang:)`. Numbers go through `String(value)`, which is always Latin, then `Bidi.ltr`. Never interpolate a number into a `LocalizedStringKey`, and never use `Text(_, format:)` for a figure.

**Ticket number under Dynamic Type.** It is sized by width, not by the user's text size, so it needs no scaling and cannot clip.

```swift
Text(verbatim: number)
    .font(.system(size: 112, weight: .semibold).monospacedDigit())
    .lineLimit(1)
    .minimumScaleFactor(0.25)
    .frame(maxWidth: .infinity)
```

| Case, iPhone Air, 420 pt wide, inner 356 | Result |
| --- | --- |
| `T-014`, 5 characters | About 112 pt, capped |
| `D-GP-023`, 8 characters | About 70 pt, fills the width |
| AX3 | The same. The smallest result stays above AX3 body at 40 |
| iPhone SE, 375 pt wide | `T-014` about 100 pt, `D-GP-023` about 62 pt |

This is the web's `min(112px, width / (chars × 0.62))`. The stage track and rows below it do grow.

## 3. Layout

### 3.1 Scale

| Token | Value | Use |
| --- | --- | --- |
| `DS.Space.xxs` | 2 | Footer line gap |
| `DS.Space.xs` | 4 | Field to its error, label to its value |
| `DS.Space.s` | 8 | Label to field, inside a chip row |
| `DS.Space.m` | 12 | The web's gap. Between blocks on a screen |
| `DS.Space.l` | 16 | Side gutter, card padding |
| `DS.Space.xl` | 24 | Ticket card vertical padding, before a new group |
| `DS.Space.xxl` | 32 | Above the footer |

| Token | Value | Use |
| --- | --- | --- |
| `DS.Radius.card` | 8 | Cards, bubbles, called block, notice |
| `DS.Radius.control` | 6 | Buttons, fields, chips, wait badge, skeleton |
| `DS.Stroke.edge` | 1 pt | Card, control and row rule. Not `1/displayScale`: the web's 1 px is 1 pt, and a third of a point in `#e6e6e6` vanishes |
| `DS.Stroke.focus` | 2 pt | Focused field |
| `DS.Size.minTarget` | 44 | Every target. Apply `.contentShape` where the glyph is smaller |
| `DS.Size.button` | 50 | Primary, secondary, destructive minimum height |
| `DS.Size.buttonLarge` | 56 | Call 999, the mic button |
| `DS.Size.field` | 48 | Text field minimum height |
| `DS.Size.row` | 44 | Key-value row minimum height |
| `DS.Size.rowTwoLine` | 56 | Two-line row minimum height |

Always `RoundedRectangle(cornerRadius:, style: .continuous)`. Pills use `Capsule()`. Sizes are minimums, so text can grow. Never set a fixed height on anything that holds text. Spacing does not scale with Dynamic Type.

### 3.2 `PatientScaffold`

Every patient screen uses it, so the bar, gutter and footer cannot differ.

| Part | Rule |
| --- | --- |
| Ground | `DS.Color.ground`, ignoring safe areas |
| Product title | `ToolbarItem(.principal)`, `common.product`, `.barTitle`. Absent on S01, where the lockup is the name. S06 has no bar |
| Back | System back only. `.toolbarRole(.editor)` so it shows the chevron with no previous title, on every OS. Swipe back works. Set `.navigationTitle(screenName)` for the long-press menu |
| Language toggle | `ToolbarItem(.topBarTrailing)`. `LanguageToggle` is on every screen |
| Bar mode | `.navigationBarTitleDisplayMode(.inline)`. No large titles: 34 pt is over the taste cap, and it would displace the product name |
| Screen title | First item of the content, `ScreenTitle`, `.screenTitle`, header trait |
| Content | `ScrollView`, `.scrollBounceBehavior(.basedOnSize)`, `.scrollDismissesKeyboard(.interactively)`, side gutter `DS.Space.l`, `DS.Space.m` between blocks |
| Footer | `PatientFooter` on every screen. See below |
| Tone | `.default` or `.emergency`. The emergency tone drops the toolbar and draws its own header. See S06 |

### 3.3 `PatientFooter`

Two lines, `footer.demo` then `footer.ai`, centred, `.caption`, `muted`, `DS.Space.xxs` apart, `DS.Space.m` above and below. On S06 it is `emergencyText`. `footer.ai` shows whenever AI mode is simulated, which is always in this app: there is no model, and Clinic server mode refuses any other mode. Never hide it.

| Situation | Behaviour |
| --- | --- |
| Short screen | Last item in the scroll content. The content has `minHeight` equal to the viewport, so the footer rests at the bottom edge |
| Long screen | Follows the last block, `DS.Space.xxl` below it. Never overlaps content. Reached by scrolling |
| S05 chat, regular sizes | Pinned in the bottom inset under the composer. Removed while the keyboard is up, since the keyboard covers that area. Returns when it goes down |
| S05 chat, accessibility sizes | Last item in the transcript, so the composer keeps its room |
| S08 map view | Last item in the details scroll under the map |
| AX3 | English runs about 3 lines plus `footer.ai`, about 150 pt. Never truncated, no `lineLimit`, no scale factor. It is always in the flow, except that S06's sits above the pinned Call 999 |

This matches the web: the footer follows the content and rests at the bottom. A pinned footer would cost 150 pt at AX3.

### 3.4 Adapting at accessibility sizes

Test with `dynamicTypeSize.isAccessibilitySize`.

| Component | Regular | Accessibility sizes |
| --- | --- | --- |
| `StageTrack` | Three columns | Vertical list, first stage on top |
| `KeyValueRow` | Label and value on one line | Label above value, both start-aligned |
| `ListRow` | Text, pill, chevron in a row | Pill drops under the text, chevron stays |
| Title with a pill, S03 | Same row | Pill drops under the title |
| Composer input | Field and Send on one row | Field above Send |
| S08 | Starts on the map | Starts on the list |

## 4. Components

Accessibility identifiers keep the web's `data-testid` values, such as `language-toggle`, `footer`, `footer-ai`, `ticket-number`.

### 4.1 Buttons

All are `ButtonStyle`s. Labels wrap. No `lineLimit`. All press with scale 0.97 and `DS.Motion.press` on touch-down, then `DS.Motion.release`. No scale with Reduce Motion. Loading keeps the label and adds a `ProgressView` before it, tinted to the label, and disables the button.

| Style | Rest | Pressed | Disabled | Size |
| --- | --- | --- | --- | --- |
| `PrimaryButtonStyle` | `primaryFill`, `primaryText`, no edge | `primaryPressed` | `disabledFill`, `disabledText` | Full width, 50 min |
| `SecondaryButtonStyle` | `surface`, `ink`, 1 pt `control` | `raised` | `surface`, `disabledText`, 1 pt `hairline` | Full width, 50 min |
| `DestructiveButtonStyle` | `surface`, `negative`, 1 pt `negative` | `pillNegativeFill` | As secondary | Full width, 50 min. Text and edge only: full red stays on S06 |
| `QuietButtonStyle` | `ink` text, no fill | Opacity 0.6 | `muted` | 44 min. Underlined when Button Shapes is on |
| `EmergencyCallButtonStyle` | `emergencyCallFill`, `emergencyCallText`, `.callButton` | `emergencyCallPressed` | Never disabled | Full width, 56 min |
| `ChipButtonStyle` | As secondary, `.label`, radius 6, 12 side padding | `raised` | As secondary | Hug, 44 min |

One `PrimaryButtonStyle` per screen at a time. Destructive actions confirm through `.confirmationDialog` with `role: .destructive`, only for what cannot be undone.

### 4.2 Containers and rows

| Component | Spec |
| --- | --- |
| `Card` | `surface`, 1 pt `hairline`, radius 8, padding 16. `flush: true` drops the padding for rows. No shadow |
| `ListRow` | Tappable row in a flush card. Padding 12 and 16, min 56 for two lines. Title `.bodyStrong`, subtitle `.secondary` `muted`, optional `Pill`, `chevron.forward` in `muted`. 1 pt `rule` above each row but the first, text-edge to text-edge. Pressed fill `raised`. Rows that do not open keep height and drop the chevron |
| `KeyValueRow` | Label `.secondary` `muted`, value trailing-aligned. S10 and S08 values use `.statValue`, S03 values use `.label`. Min 44. Same rule as `ListRow`. Numbers end on one trailing edge |
| `Pill` | `Capsule`, fill and text from the four pairs, `.pill`, padding 2 and 8, min height 24, `.fixedSize()`. Never squeezed. Beside a value, never above a heading |
| `Notice` | `noticeFill`, 1 pt `noticeEdge`, `noticeText`, `.secondary`, radius 8, padding 12 |
| `ScreenTitle` | `.screenTitle`, `ink`, header trait, leading aligned |

### 4.3 Text field: `DSTextField`

| Part | Spec |
| --- | --- |
| Label | Above the field, `.label`, `ink`, gap 8. Never a placeholder used as a label |
| Field | `surface`, 1 pt `control`, radius 6, min 48, side padding 12, `.body`. `monospacedDigit` on QID, code and door code |
| Focused | 2 pt `ink` edge, drawn as an overlay so nothing shifts |
| Error | 1 pt `negative` edge, message below in `.secondary` `negative`, gap 4, tied by `.accessibilityHint` |
| Hint | Below, `.caption` `muted` |
| Disabled | `raised` fill, `disabledText` |
| Placeholder | `muted`, which passes 4.5:1 |

### 4.4 Language toggle: `LanguageToggle`

Shows the other language in its own script: `العربية` when in English, `English` when in Arabic, `.label`, min 44 by 44.

| Where | Look |
| --- | --- |
| iOS 26 and later, in the bar | Plain label. The system's toolbar capsule is its edge. No fill or border of ours |
| iOS 18 to 25, in the bar | `surface` fill, 1 pt `control`, radius 6, 12 side padding, as on the web |
| S06, on all systems | Clear fill, 1 pt `emergencyText`, `emergencyText` label, pressed `emergencyPressed` |

Its VoiceOver label is in the target language. SwiftUI has no modifier for this, so the language travels on the string: the label is an `AttributedString` with `languageIdentifier` set to the target language, passed through `.accessibilityLabel(Text(_:))`. It sits in the top-trailing place on every screen, so in Arabic it is on the left. Behaviour is in section 7.

### 4.5 Stage track: `StageTrack`

Three stops in order: `ticket.stepTriage`, `ticket.stepDoctor`, `ticket.stepPharmacy`.

| State | Marker | Label | Connector to the next stop |
| --- | --- | --- | --- |
| Done | `checkmark`, 14 pt, `ink` | `.secondary`, `ink` | 2 pt `ink` |
| Current | 12 pt filled circle, `hue` | `.secondaryStrong`, `hue` | 2 pt `control` |
| Future | 12 pt ring, 2 pt `control` | `.secondary`, `muted` | 2 pt `control` |

The three states differ by shape and weight, so colour is never alone. Connectors run between markers, centred on them. The whole track is one VoiceOver element: "Steps of your visit, Triage, step 1 of 3". The track follows reading direction, so in Arabic triage is on the right, as on the web. When the visit has no current stage, every stop is future. In `.compact` style for Live Activities, labels use `.caption` and the markers shrink to 8 pt.

### 4.6 Ticket number block: `TicketNumberBlock`

A `Card` with 24 vertical padding, centred, holding the number, `DS.Space.l`, then `StageTrack`. Number in `hue`, using the code in section 2. Hidden label `ticket.numberLabel`. `.speechSpellsOutCharacters()` so VoiceOver reads T, 0, 1, 4 rather than a minus sign. It is `.updatesFrequently` and announces changes. With no number, the block shows `ticket.nextStep` in `.section` and `ink`. A reserved visit never uses this block.

### 4.7 Wait badge: `WaitBadge`

For map pins, using `Annotation` with `anchor: .center`.

| Part | Rest | Selected |
| --- | --- | --- |
| Fill | `surface` | `primaryFill` |
| Text | `ink`, `.badge` | `primaryText` |
| Edge | 1 pt `control` | None |

Height 28, side padding 8, radius 6, hit area 44 by 44. Text is `12 min` or `12 د`, value isolated. A missing wait shows `–`. Selected sits on top. VoiceOver label `centre.pinLabel`. The app direction stays inside the badge, even though the map itself is forced left to right.

### 4.8 Chat

| Component | Spec |
| --- | --- |
| `ChatBubble` assistant | Leading side, `surface`, 1 pt `hairline`, `ink`, `.body`, radius 8, padding 12 and 8, max width 85% |
| `ChatBubble` user | Trailing side, `primaryFill`, `primaryText`, same shape |
| Text direction | Each bubble's text is wrapped with `Bidi.auto`, so an English sentence reads correctly in an Arabic chat. Alignment follows the screen |
| `ThinkingBubble` | Assistant shape, `chat.thinking` in `muted`. Static words, no dots animation. Announced politely |
| Gap | 8 between bubbles. No tails, avatars or timestamps |
| `SummaryCard` | `Card`: service `Pill`, summary text, `chat.summary.check` as `.section`, Yes primary, Change secondary. `chat.summary.unsent` in `warning` disables Yes |

`Composer`, in the bottom safe-area inset, `ground` fill, 1 pt `hairline` on top, padding 12 and 16:

| State | Content |
| --- | --- |
| Idle, empty | Field with `chat.input.placeholder`, Send secondary and disabled, then the mic as `PrimaryButtonStyle` at 56, `mic.fill` and `voice.start` |
| Idle, with text | Send becomes primary, mic becomes secondary, so one primary stays |
| Listening, `ListeningPanel` | `surface` panel: 8 pt `ink` dot, `voice.listening`, timer `0:12`, live transcript in `.secondary`, Stop primary. Live region. The dot does not pulse |
| Transcribing | `voice.transcribing` in `muted` with a spinner. On device this is brief |
| Confirm, `TranscriptConfirmPanel` | `voice.confirm.check` as `.section`, editable field, Send primary, Try again and Clear quiet in one row |
| Error | `voice.error.*` in `.secondary` `negative` above the field. Focus moves to the field |

Send uses `arrow.up`, which never mirrors. Send's text label stays visible, as on the web. In accessibility sizes the field and Send stack.

### 4.9 Loading and errors

| Component | Spec |
| --- | --- |
| `SkeletonBar` | `skeleton` fill, radius 6, the real size of what will land, card-sized blocks radius 8. Still. No shimmer, no pulse. Hidden from VoiceOver. The container says loading once |
| Rule | Labels and headers show at once, values are bars. Nothing shifts when data lands. A refresh keeps old values on screen |
| `ErrorBlock` | Inside the block that failed, never full screen. `surface`, 1 pt `hairline`, radius 8, padding 12 and 16. `.secondary` `ink` message, trailing `common.retry` as a quiet button, 44 min, underlined. Wraps at accessibility sizes. No red fill. Announced as an alert |
| `Dash` | `–` in `muted` at the surrounding size, label `ticket.notKnown`. A real zero prints `0` |

## 5. Platform stance

Xcode 27.2 builds against SDK 27.2. The review simulator is iOS 26.5. The floor is iOS 18.0. The web bans custom glass.

**Ruling. System chrome keeps the system material. No custom glass or blur is added anywhere. Everything that belongs to Dawri is opaque.**

| Rule | Detail |
| --- | --- |
| Do not opt out | Never set `UIDesignRequiresCompatibility`. Bars, sheets, the back button and segmented controls take whatever the OS draws |
| Do not opt in | No `.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`, `.background(.ultraThinMaterial)` or any `Material`, no `UIVisualEffectView`, no `.blur` |
| Leave chrome alone | No `.toolbarBackground`, no `UINavigationBarAppearance`, and no `.presentationBackground` on sheets. Sheet content sets no background, so the OS sheet shows through |
| Our surfaces | Cards, buttons, bubbles, badges and the composer are opaque tokens, on every OS, in the same pixels |
| Availability | One branch only, in `LanguageToggle`. `if #available(iOS 26, *)` drops our fill and edge, so a border never sits inside the system capsule. No other branching on OS version |

| Element | iOS 26 and later | iOS 18 to 25 | Why both look intended |
| --- | --- | --- | --- |
| Nav bar | System glass, edge effect | Transparent at rest, system material once scrolled | At rest the ground runs under it on both |
| Back | Glass chevron | Plain ink chevron | Same place, tinted ink |
| Language toggle | System capsule | Our 1 pt bordered control | Same place, size and label |
| Segmented picker, S08 | System look | System look | Native on each |
| Sheets | System material at partial heights | Standard sheet | The content is plain cards |
| Live Activity | Opaque `surface` tint | Opaque `surface` tint | We set the tint so contrast is known |

The review simulator proves the new look. The brief names no iOS 18 runtime, so the iOS 18 column above is a build rule, checked by reading code and not by screenshots.

## 6. Motion and interaction

### 6.1 Springs

Named constants only. Each is `Animation.spring(response:dampingFraction:)`.

| Name | Response | Damping | Use |
| --- | --- | --- | --- |
| `DS.Motion.push` | 0.40 | 1.0 | An in-place step within one screen, such as S09 reserved to expired, with `.transition(.push(from: .trailing))`, which mirrors in Arabic. The system stack's own push and swipe are never overridden |
| `DS.Motion.sheet` | 0.35 | 1.0 | In-screen panels that rise, such as `TranscriptConfirmPanel`, along the path they leave by. The system's sheet keeps its own spring |
| `DS.Motion.press` | 0.12 | 1.0 | Touch-down |
| `DS.Motion.release` | 0.28 | 1.0 | Touch-up |
| `DS.Motion.stage` | 0.40 | 1.0 | Stage track marker and connector |
| `DS.Motion.number` | 0.30 | 1.0 | Ticket number swap, counts |
| `DS.Motion.crossfade` | `easeInOut(duration: 0.18)` | n/a | The Reduce Motion replacement, and the language switch |

These follow Apple's move value, response 0.4 and damping 1.0, tightened for small things. Apple's drawer value, response 0.3 and damping 0.8, is not used, because the app has no custom draggable surface. If one is ever added, it takes that value and the finger's release velocity.

### 6.2 What animates

| Animates | How |
| --- | --- |
| Press | Scale 0.97 |
| Stage change | Marker and connector with `.stage`. Same frame as the haptic |
| Ticket number change | New number enters with opacity and a 6 pt rise, `.number`. Keyed by number, so it plays once |
| People ahead, wait | `.contentTransition(.numericText(value:))`, `.number` |
| Called block, serving card | Opacity and 6 pt rise, `.number` |
| New chat bubble | Opacity and 8 pt rise, `.number`, then scroll to the end |
| Panels | `.sheet` |
| Selected pin | Fill change, `.press` |

| Does not animate | Why |
| --- | --- |
| Screen content on arrival | Nothing performs an entrance. App screens only animate feedback |
| Countdown tick | A clock jumps. `.contentTransition(.identity)` |
| S06 appearing | It must interrupt. `disablesAnimations` on the presenting transaction. No slide up |
| Skeleton to content | The swap is instant, the layout holds |
| Footer, titles, pills, list rows | Static |
| Theme change | System |
| Map camera on a pin tap | The map stays put. Only the selection changes |

### 6.3 Interruptibility

- Never block input during a transition. No `.disabled` or `allowsHitTesting(false)` tied to animation state, and no waiting on an animation's completion.
- Springs in SwiftUI retarget from the live value and carry velocity, which is why every touched element uses one. No `.linear` or `.easeInOut` on a touched element.
- A live update arriving mid-swipe never moves the navigation stack. Stage changes within S10 update in place. A step to a new screen waits until the swipe ends.
- As built, the gate under a held swipe already knows the visit has moved, so for that moment the screen under the finger is the gate's empty scaffold, not the old screen. When the swipe cancels, the new screen replaces it. When the swipe finishes, the entry is gone, and nothing is pushed over Home. `SwipeHoldTests` proves both by holding a swipe across a demo step.
- Press cancels if the finger drags away, and recovers if it returns. `ButtonStyle` gives this.

### 6.4 Haptics

Use `.sensoryFeedback` on the same state change that drives the visual, so they fire on one frame. Fewer is better. Plain buttons get none.

| Event | `DS.Haptic` | SwiftUI feedback | Generator |
| --- | --- | --- | --- |
| Stage change | `.stageChange` | `.success` | `UINotificationFeedbackGenerator.success` |
| Called to a counter | `.called` | `.warning` | `UINotificationFeedbackGenerator.warning` |
| Visit complete | `.visitComplete` | `.success` | `UINotificationFeedbackGenerator.success` |
| Ticket activated at arrival | `.activated` | `.success` | `UINotificationFeedbackGenerator.success`. As built, it plays on S10 as it appears after a stage move, on the frame the number does, not on S09 when the request returns. Opening S10 from Home plays nothing |
| Login or code failed, too far | `.failed` | `.error` | `UINotificationFeedbackGenerator.error` |
| Message sent | `.sent` | `.impact(weight: .light)` | `UIImpactFeedbackGenerator(.light)` |
| Mic start | `.micStart` | `.impact(weight: .medium)` | `UIImpactFeedbackGenerator(.medium)`, fired before the audio session starts, because iOS mutes haptics while recording |
| Mic stop | `.micStop` | `.impact(weight: .light)` | Fired after the session ends |
| Pin, row, chip, picker, star | `.select` | `.selection` | `UISelectionFeedbackGenerator` |
| QR code read | `.scanned` | `.success` | `UINotificationFeedbackGenerator.success` |
| **S06 appears** | `DS.Haptic.emergency()` | Not used | `UINotificationFeedbackGenerator().notificationOccurred(.error)`: fire and forget, once, no `prepare()`, nothing awaits it |
| **Call 999 tap** | None | None | None. `openURL` runs on touch-up with nothing before it |

Nothing on S06 sits on the path to the call: no haptic, animation, confirmation of ours, network read or `await`. iOS may show its own call prompt for `tel:`, which we cannot remove and do not add to.

### 6.5 Reduce Motion

Read `accessibilityReduceMotion`. The state change always stays visible.

| Motion | Replacement |
| --- | --- |
| Press scale | None. The fill change stays |
| System push, swipe, sheet | The system's own |
| In-place step | `.opacity`, `.crossfade` |
| Rising panel | `.opacity`, `.crossfade` |
| Stage marker and connector | Fill cross-fades, connector changes colour. No travel |
| Ticket number | `.opacity`, `.crossfade`, no rise |
| Counts | `.contentTransition(.opacity)` |
| Called block | `.opacity`, `.crossfade` |
| New bubble | `.opacity`, `.crossfade`. Scroll to end without animation |
| Language switch | Same cross-fade. It has no travel |

### 6.6 Reduce Transparency, Increase Contrast and others

| Setting | Behaviour |
| --- | --- |
| Reduce Transparency | Nothing of ours is translucent, so no code runs. System bars and sheets frost themselves |
| Increase Contrast | Section 1.3, through the dynamic colours, plus S06 field `#a81d23` |
| Differentiate Without Color | Already true: stage markers differ by shape, pills carry words, errors carry text |
| Button Shapes | `QuietButtonStyle` underlines. The rest already have shapes |
| Bold Text | System. Layouts must still fit |
| VoiceOver | All labels in the current language. Live updates are announced, called at high priority through `AccessibilityNotification.Announcement`. The countdown has a value and does not announce each second |

## 7. Right to left

### 7.1 What mirrors

| Element | Rule |
| --- | --- |
| Layout, alignment, stacks | Mirror. Use leading and trailing only, never left, right, or `.offset(x:)` for layout |
| Back, swipe back | Mirror. Back on the right, swipe from the right edge |
| Chevrons | `chevron.forward` and `chevron.backward`, which mirror. Never `chevron.left` or `chevron.right` |
| Stage track | Mirrors. Triage is on the right, connector fills from the right. It reads as a sequence, and the web does the same |
| Bubbles | User on the left, assistant on the right, as on the web |
| Language toggle | Top left in Arabic |
| Star rating | First star on the right |
| In-place step | Mirrors, through `.push(from: .trailing)` |
| List icon | `list.bullet` has a right-to-left form, and the system picks it |

### 7.2 What must not mirror

| Element | Rule |
| --- | --- |
| Ticket numbers, `T-014`, `D-GP-023`, `P-031` | Always left to right, as a unit. `Bidi.ltr`, or `Text(verbatim:)` when alone |
| QIDs, `DEMO-10001` | Left to right. The field sits inside `.environment(\.layoutDirection, .leftToRight)` with `.multilineTextAlignment(lang == .ar ? .trailing : .leading)`, so it stays under its label |
| One-time code, door code | Same. Eastern Arabic digits from an Arabic keyboard are normalised to Latin before use |
| Phone numbers, 999 | Left to right, isolated in a sentence |
| Countdown, clocks, `0:12` | Left to right, as a unit |
| Server address | Left to right and left-aligned in both languages |
| Figures in a measure, `12 min`, `7.2 km` | Figure isolated, the unit follows the language, so Arabic reads `12 د` |
| Map | `Map` gets `.environment(\.layoutDirection, .leftToRight)`, as the web does. East stays right, and the compass and attribution stay put |
| Map controls | Not mirrored, for the same reason |
| Symbols with no direction | `mic.fill`, `phone.fill`, `location`, `map`, `qrcode.viewfinder`, `checkmark`, `star`, `arrow.up`, `gearshape` stay as they are |
| Wordmark | Never flipped. Latin `Dawri` in the lockup stays left to right |

### 7.3 Isolating mixed text

Use Unicode isolates, never LRM or RLM marks.

| Helper | Wraps with | Use |
| --- | --- | --- |
| `Bidi.ltr(_:)` | U+2066 ... U+2069 | Numbers, codes and figures inside a sentence |
| `Bidi.auto(_:)` | U+2068 ... U+2069 | Text whose language is unknown: chat, transcripts, medicine names, server messages. The web's `dir="auto"` |
| `Bidi.fill(_:_:)` | `Bidi.ltr` on each value | Port of `Filled`: calls `Strings.translate` with each value wrapped first |

Examples: `ticket.goNow` with `Triage 1`, `reserved.tooFar`, `emergency.distance`, `complete.followUpLine`. Strip the isolates from any `accessibilityLabel` and any string sent to the service. A rule hit must never depend on them.

### 7.4 Language toggle mid-flow

| Rule | Detail |
| --- | --- |
| Default | Arabic, with no launch argument. `LanguageState` holds it: a tapped choice outranks the record until logout |
| Where state lives | Language, the navigation path, drafts and in-flight work sit in stores above the `NavigationStack` |
| How it applies | Every change goes through `AppModel.switchLanguage`, which sets the language and calls `DirectionBridge.apply`. The root `\.locale` and `\.layoutDirection` follow the language, but they do not reach the UIKit that hosts the stack, so `DirectionBridge` does that: the appearance proxies for views made later, then `semanticContentAttribute` and `traitOverrides.layoutDirection` on the window, and `semanticContentAttribute` on the navigation controller's view, its bar and the bar's subviews. That moves the back chevron and the swipe edge in place. **Never rebuild the stack with `.id(language)`.** The stack has no `.id`, and adding one breaks the path |
| Path | Kept exactly. The patient stays on the same screen |
| Input | Login fields, chat draft and transcript survive, because they live in the stores, not in `@State` of a screen |
| In-flight work | Requests, the countdown, the listening session and the demo timer continue. The speech recogniser restarts in the new language if listening |
| Chat | Messages already sent keep their language. New replies use the new language |
| Server-written text | Any field with an `_ar` and `_en` pair swaps at once, such as `reply_ar`, `message_ar` and suggestion reasons |
| Motion | `.crossfade` over the stack. No slide. Scroll position may reset, except that chat returns to the newest message |
| S06 cover | Attached above the `NavigationStack`, so a switch does not dismiss it. It re-renders in place |
| Live Activity | Its `lang` is fixed for its life, so a switch ends it and starts a new one in the new language, while the app is in front |
| System text | Permission prompts follow the phone's language, not the in-app choice. Localise `InfoPlist.strings` in both, and accept this limit |

## 8. Screens

**Routing.** This uses `Route`, `gatedRoute` and `routeFor` from DawriCore. One `NavigationStack`, with `.welcome` as its root before login and `.home` after. `.login`, `.who`, `.consent`, `.history` and `.settings` push. A visit holds a single `.visit(id:, screen:)` entry above Home. When the stage moves the screen on, that entry is **replaced**, not stacked, through `gatedRoute`. This is the web's `navigate(..., { replace: true })`, so Back from any visit screen goes to Home and can never reach a stage the visit has passed. The replacement keeps the system's push animation. If the system does not animate it, leave it unanimated rather than faking one. `.visit(id:, screen: .emergency)` is never pushed: the root reads it and shows the S06 cover. Phase 1's placeholder may stay a push with its back button hidden, and the S06 build moves it to the cover.

Each screen states the one question it answers (taste §2.2). Every visit screen also has `VisitGate` states: loading with `SkeletonBar`s under the screen's title, an `ErrorBlock` with retry, and gone, which returns to S03 with `home.demoReset`.

### S01 Welcome and language (Phase 1 builds this for real)

Question: what is this, and how do I start?

| Element | Rule |
| --- | --- |
| Scaffold | `PatientScaffold(title: nil, showsProductTitle: false, footer: .flow)`. No back. Root of the stack |
| Language control | `LanguageToggle`, top trailing: top right in English, top left in Arabic |
| Settings | `gearshape` in `.topBarLeading`, `ink`, 44 by 44, label `settings.title`. Mode must be reachable before login |
| Lockup, `ProductLockup` | The mark, then 8 pt, then the Latin name `Dawri` in `.section`. Same lockup in both languages, so nothing changes shape on a switch. Bilingual lockups are normal in the Gulf. Start-aligned: left in English, right in Arabic |
| Mark | `Wordmark` asset, template rendering, tinted `ink`. 132 by 66 pt, a fixed size that does not scale, since it is a graphic. Black on the ground in light, `#f4f4f5` in dark |
| Lockup accessibility | One element, label `common.product`, header trait. The image and Latin line are hidden from VoiceOver |
| Purpose | 12 pt below the lockup. `welcome.purpose`, `.lead`, `ink`, start-aligned. Full ink, because it is the screen's one sentence |
| Login action | `welcome.login`, `PrimaryButtonStyle`, full width, id `welcome-login`. The one primary. Pushes S02 |
| Footer | `PatientFooter`, flow, resting at the bottom |
| Hue, red | Neither appears here |

Vertical placement:

| Size | English | Arabic |
| --- | --- | --- |
| Default | Gap above the lockup is 18% of the viewport height. Lockup and purpose hang from that line, so the top of the mark sits at the same place in both languages, and a language switch moves nothing. Free space sits between the purpose and the button. The button rests `DS.Space.l` above the footer, in thumb reach | Same line, same anchors, mirrored. The purpose is usually one line against English's two, and the button does not move |
| iPhone Air, 912 pt, viewport about 770 | Gap about 140. Lockup 66 + 8 + 22. Purpose 2 lines, about 50. Button 50. Footer 2 lines, about 40 | Same, purpose about 26 |
| AX3 | Free space collapses. Gap above the lockup is `DS.Space.l`. Order holds: lockup, 12, purpose about 4 lines at 43 pt, 24, button about 2 lines, 16, footer about 4 lines. Total about 670, so it fits the Air | Same, with Arabic line spacing. Purpose about 3 lines. Footer `.footnote`, about 4 lines |
| AX3, iPhone SE, viewport about 600 | The whole column scrolls. The button stays on the first screen at about 550. The footer is reached by scrolling | Same |

Mark stays 132 pt at AX3. Nothing truncates. The button text wraps.

Build the gap with a `Color.clear` of `containerRelativeFrame(.vertical)` at 0.18 of the viewport at regular sizes. Use the `minHeight` column from section 3.3, so `Spacer()` above the button takes the free space.

### S02 Login

Question: who are you?

| Field | Spec |
| --- | --- |
| On it | `login.title`. `login.demoPatients` as `.label`, three `ChipButtonStyle` chips in a wrapping flow. `DSTextField` `login.qid`. `DSTextField` `login.otp` with hint `login.otpHint`. `login.submit` |
| Hierarchy | Chips first, because they are the 3-tap demo path. Then the form |
| Primary | `login.submit`. Disabled until both fields have text. Chips are chips |
| Native | Push, keyboard handling, `.textContentType(.oneTimeCode)`, `.keyboardType(.numberPad)` on the code, `.textInputAutocapitalization(.characters)` and `.autocorrectionDisabled()` on the QID, `.submitLabel(.go)`, `.scrollDismissesKeyboard` |
| Default state | Empty, button disabled |
| Loading | Spinner in the acting chip or button. All others disabled. Spinner, label stays |
| Error | `unknown_qid` under the QID, `invalid_otp` under the code, both with `.failed` haptic. Anything else: `ErrorBlock` that retries the same attempt |

### S03 Home

Question: do I have a visit open, and how do I start one?

| Field | Spec |
| --- | --- |
| On it | Patient name as `ScreenTitle`, `home.demoData` neutral pill on the same row. Optional `Notice`. `home.openVisits` with `ListRow`s. Record card with `KeyValueRow`s for `home.registeredCentre` and `home.allergies`. `home.start`. `home.history` and `home.logout` as quiet buttons, one at each end of a row |
| Hierarchy | An open visit comes before everything |
| Primary | `home.start`, primary with no open visit. With an open visit it turns secondary, and the row is the next step |
| Native | Stack root after login, `.refreshable`, gear in `.topBarLeading` as on S01 |
| No visit | No open section |
| Active visit | `ListRow`: name, centre, status pill, chevron. Pill neutral. Expired pill warning. Emergency today pill negative. Tapping opens the visit, or S06 |
| Loading | Name bar, card-sized bar. Button disabled until `me` is ready |
| Error | `ErrorBlock` in place of the record, or below the button for the visit list |
| Demo reset | `Notice` `home.demoReset` |
| Allergies | `home.noAllergies` in `muted`, or pills. Penicillin is the warning pill, others neutral |

### S04 Who is this for

Question: who is the visit for?

| Field | Spec |
| --- | --- |
| On it | `who.title`. Flush `Card` of `ListRow`s: `who.me` with name and age, then each dependent with `who.age` |
| Primary | None. The rows are the choice |
| Native | Push, row press state |
| States | Loading skeleton of the card. `ErrorBlock`. No dependents skips to consent with no flash |

### Consent (before S05)

Question: do I agree to the chat?

| Field | Spec |
| --- | --- |
| On it | `consent.title`. Optional `consent.forPerson`. `Card` with the four points in `.body`: `consent.why`, `consent.limits`, `consent.privacy`, `consent.demo`. `consent.agree` |
| Primary | `consent.agree` |
| Native | Push. Back goes to S04 or S03 |
| States | Loading in the button. `ErrorBlock`. `emergency_today` opens S06. `active_visit` opens that visit |

### S05 Reception chat

Question: what brings you in, one question at a time?

| Field | Spec |
| --- | --- |
| On it | `screen.chat`. Transcript of `ChatBubble`s. `Composer` in the bottom inset. Footer under it |
| Hierarchy | The newest question, then the mic |
| Primary | One at a time: mic when empty, Send with text, Yes on the summary, Stop while listening, Send in confirm |
| Native | `Speech` with `requiresOnDeviceRecognition`, `.safeAreaInset(edge: .bottom)`, automatic keyboard avoidance, `ScrollViewReader` to the end, `.scrollDismissesKeyboard(.interactively)` |
| Listening | `ListeningPanel` with the live transcript |
| Thinking | `ThinkingBubble`. Field read-only, Send and mic disabled |
| Error-retry | `ErrorBlock` above the composer with retry when the send can repeat. `chat.timeout` keeps the message in the box |
| Transcript confirm | `TranscriptConfirmPanel`. Nothing is sent until the patient taps Send |
| Summary | `SummaryCard` at the end of the transcript. `chat.summary.yes` primary, `chat.summary.change` secondary, which focuses the field. Confirm error in `ErrorBlock` |
| Unsent | `chat.summary.unsent`, Yes disabled. Rules read only what is sent |
| Voice unavailable | Mic disabled or `voice.unavailableOnDevice` in `.secondary`, focus to the field. Never falls back to server recognition. Permission denied: `voice.error.denied` |
| Red flag | S06 opens at once, with no animation, over a closed chat |
| Scripted note | `chat.scripted` is not shown. The web shows it only in real AI mode, and the footer already says AI: simulated |

### S06 Emergency

Question: what do I do right now? Answer: call 999.

Presentation: `.fullScreenCover` at the root, with `disablesAnimations`, no toolbar, no back, and no swipe out. `.preferredColorScheme(.dark)` on the cover gives white status bar text. The tokens are constants, so the screen looks the same in either theme.

Layout, top to bottom: a two-part screen.

| Region | Content |
| --- | --- |
| Scroll area | Header row: product name, `emergencyText`, and `LanguageToggle(.emergency)`. `emergency.title` in `.emergencyTitle`. Reply in `.body`. Nearest department card. Override. Footer |
| Pinned bottom | `emergency.call`, `EmergencyCallButtonStyle`, `phone.fill`, side gutter 16, 12 above, safe area below. Fixed in place at every size, so it can never scroll off even at AX3 or with the long self-harm reply. This is a change from the web, which has it inline |

VoiceOver. The 999 action must be the first thing reached.

```swift
VStack(spacing: 0) {
    ScrollView { /* header, title, reply, card, override, footer */ }
    Button { openURL(call999) } label: { /* Call 999 */ }
        .buttonStyle(EmergencyCallButtonStyle())
        .accessibilitySortPriority(1)            // read before the scroll area
        .accessibilityFocused($callFocused)      // landing point on arrival
}
.accessibilityElement(children: .contain)
```

The screen has no navigation bar, so nothing outranks it. `callFocused` is set in `.onAppear`. The order after it is title, reply, card, map link, override, language toggle, footer. The product name is hidden from VoiceOver. The S06 builder proves the order with a UI test or Accessibility Inspector.

As built, three things differ from the sketch above, because the sketch did not work on iOS 26.5:

- `accessibilitySortPriority` orders elements inside the scroll, but it does not move a button ahead of the `ScrollView`, which is a platform element. So the pinned part comes first in view order, and `PinnedFirstLayout` in `PatientScaffold.swift` places it at the bottom.
- UIKit keeps the stack in the window under the cover. So the cover carries `.accessibilityAddTraits(.isModal)`, and `DirectionBridge.stackIsCovered` hides the navigation controller's view from accessibility while it is up. XCTest still lists that stack, so any test on S06 reads the cover's own elements through `screen-emergency`.
- `MKMapItem(placemark:).openInMaps()` compiles on the iOS 18 floor with no deprecation warning, so `emergency.map` uses it.

| Field | Spec |
| --- | --- |
| Primary | Call 999. Works with no server, no visit data, no network |
| Native | `openURL` with `tel://999`, `.fullScreenCover`, `MKMapItem.openInMaps` for `emergency.map`, in place of the web's OSM link |
| Default | As above |
| Self-harm | Reply in `.urgent`, as `text-xl font-medium` on the web. Same screen |
| Before the visit loads | Title and Call 999 at once. Nothing waits. Load error: `ErrorBlock` on the field, using the card tokens. Opened from a Home row and not from a red flag, the same field shows `screen.emergency` and tone-on-tone bars, Call 999 stays pinned, and a load error adds `emergency.home`, which is what the web's Back gave that state |
| Nearest card | `emergencyCard`, `emergencyCardMuted` label, name in `.section`, `emergency.distance`, map link underlined in `emergencyCardText` with `mappin` |
| Override | `emergency.override`, quiet, `emergencyText`. Logs, issues no ticket. Then shows `route.message` in `.bodyStrong` and `emergency.home`, which dismisses to S03. Error: `ErrorBlock` with retry |
| No ticket | Never a number, never a queue figure |

### S07 Refill

Question: can I get this without a visit?

| Field | Spec |
| --- | --- |
| On it | `refill.title`. `Card`: `refill.medicine` label, medicine in `.section`, wrapped with `Bidi.auto`. `refill.body`. `refill.message`. `refill.visit` |
| Primary | `refill.message`. `refill.visit` is secondary |
| Native | One push above S03 |
| Notice | After tapping, `Notice` `refill.notice`. Nothing is sent anywhere |
| Loading | Spinner in `refill.visit` |
| Error | `ErrorBlock` with retry above `refill.visit` |
| No medicine | `refill.usualMedicine` |
| No ticket | This route never shows a number |

### S08 Centre map

Question: where should I go, and how long will it take?

Layout: fixed control row, fixed map, then a scroll of details.

| Field | Spec |
| --- | --- |
| On it | `screen.centre` title. Control row: `Picker` `.segmented` with `centre.viewMap` and `centre.viewList`, then `centre.useLocation` quiet with `location`. Map, edge to edge, 44% of viewport height, min 220, square corners. Scroll: selected centre `Card`, suggestion `Card`, footer |
| Selected card | Name as `.section` with `centre.yourCentre` pill, three figures in a row, `centre.wait`, `centre.peopleAhead`, `centre.distance` as label over `.statValue`, then `centre.checkIn` |
| Primary | `centre.checkIn`. It sits first in the scroll, so it is always visible |
| Native | MapKit `Map` with `Annotation` and `WaitBadge`, `.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))`, Core Location, `.segmented`, no API key |
| List view | Flush `Card` of `ListRow`s, registered centre first: name, `centre.peopleAhead`, distance, wait as `.statValue`, a `checkmark` on the chosen row. Selection fill `ground`, as the web's `bg-ground`: on `raised` the neutral `centre.yourCentre` pill, whose fill is the same `#eeeeee`, disappears |
| Map selection | Tap selects, `.select` haptic. Selected badge is ink. The camera does not move |
| Loading | Bars at the size of the control row, map and card. The list never waits for the map |
| No services | `centre.empty` and `centre.home` secondary. Map and list hidden |
| Map failed | `NWPathMonitor` reports no path at entry: `Notice` `centre.mapFailed`, list only, picker hidden |
| Location failed | `centre.locationFailed` in `.secondary`. The list still works |
| Other | `centre.gpFirst` in `.secondary`. Suggestion: neutral pill, reason wrapped with `Bidi.auto`, `centre.chooseSuggested` secondary when it is not selected. Reserve failure: `ErrorBlock` in the card. `active_visit` or `emergency_today` go to that visit |
| None chosen | `centre.choosePrompt` in the card |
| Accessibility sizes | Starts on the list. Map view available at 220 |
| Until the map phase | `Screens/Visit/CentreMapSlot.swift` holds the map's place at the map's geometry: a flat `raised` ground with `centre.mapPlaceholder`, hairline top and bottom, and no pins. It is the one view MapKit replaces, and it reports a failed map through `onFail` |
| As built | The title heads the fixed part, above the control row, so the order reads title, controls, map, details. At accessibility sizes nothing is fixed and it all scrolls, so the controls cannot crowd out the details. `centre.checkIn` sits in the selected card, first in the scroll in both views |

### S09 Ticket reserved

Question: how long do I have to arrive?

| Field | Spec |
| --- | --- |
| On it | Centre name as `ScreenTitle`. `Card`, centred: `reserved.valid` in `.bodyStrong`, countdown in `.countdown`, `reserved.activates` in `.secondary` `muted`. Then actions |
| Rule | **No number and no place.** No hue. No people ahead. Sample copy is `Check-in valid for 45 minutes` |
| Primary | `reserved.here`. `reserved.useLocation` secondary. `reserved.scan` quiet, with `qrcode.viewfinder` |
| Native | Core Location for the 150 m geofence, `AVCaptureSession` scanner in a `.sheet` at `.large`, typed `reserved.codeLabel` with `reserved.codeSubmit` in the same sheet as the fallback, `TimelineView(.periodic)` for the countdown, no Live Activity yet |
| Reserved | Countdown ticks with no animation. VoiceOver: label `reserved.timeLeft`, value in minutes and seconds |
| Too far | `Notice` `reserved.tooFar`, `Bidi.fill`, `.failed` haptic |
| Location failed | `Notice` `reserved.locationFailed` |
| Wrong door | `error.wrong_door` in the sheet, below the field |
| Failure | `ErrorBlock` |
| Loading | Spinner in the acting button, the others disabled |
| Time ran out | Countdown holds at `00:00` and refetches every 5 s. The web pads minutes too, so it starts at `45:00` |
| Expired | `reserved.expiredTitle`, `reserved.expiredBody`, `reserved.chooseAgain` primary. Same route, no back into the countdown. No no-show wording |
| Camera denied | Sheet shows the typed field only |

### S10 Live ticket

Question: what is my number, and when am I called?

| Field | Spec |
| --- | --- |
| On it | Centre name as `ScreenTitle`. Optional `ticket.forPerson` in `.secondary`. `TicketNumberBlock`. Then a flush `Card` of `KeyValueRow`s: `ticket.peopleAhead`, `ticket.estimatedWait`, `ticket.goTo` |
| Hierarchy | Number, stage, then the figures. The number is the largest thing in the app and the one centred moment |
| Primary | None while waiting. The screen is watched, not worked. The called block is its answer |
| Native | Live Activity, local notifications, `.refreshable`, spring number change, VoiceOver announcements |
| Active | As above, all three rows |
| Triage, doctor, pharmacy | Track moves, number changes, `T-014` to `D-GP-023` to `P-031`. Haptic `.stageChange` |
| Called | Block in `primaryFill`, `primaryText`, `.screenTitle`, centred, radius 8, padding 16, `ticket.goNow`. Rows hidden. High-priority announcement. `.called` haptic |
| Serving | `Card`, `ticket.withTeam`, centred. Only `ticket.goTo` remains |
| Between stages | `ticket.nextStep` in the block. No rows |
| Slow | `ticket.slower` and `ticket.updatedAt` in `.caption`, after 1.5 s of polling, centred. Clinic server mode only |
| Unknown | `Dash` for missing figures. A real 0 prints `0` |
| Demo | On this phone mode only, after the rows: `demo.nextStep`, `SecondaryButtonStyle`, always saying Demo. Never looks like staff |

Wireframe:

```
┌──────────────────────────┐
│ ‹      Dawri     العربية │
│ Al Wakra Health Centre   │
│ ┌──────────────────────┐ │
│ │       T-014          │ │  hue
│ │  ●────○────○         │ │  hue on the first stop only
│ │ Triage Doctor Pharm. │ │
│ └──────────────────────┘ │
│ People ahead           3 │
│ Estimated wait    12 min │
│ Go to           Triage 1 │
│ Demo — synthetic data,   │
│ not connected to         │
│ PHCC/HMC systems.        │
│ AI: simulated            │
└──────────────────────────┘
```

### S11 Visit complete

Question: what do I do next, and how do I take my medicines?

| Field | Spec |
| --- | --- |
| On it | `checkmark` in `positive`, at `.title2` size, beside `complete.title`. Plain symbol, no circle, no emoji. Centre in `.secondary`. `Card` `complete.medicines`. `Card` `complete.followUp`. `Card` `complete.rate`. `complete.home`, `complete.history`. `complete.finalTicket` |
| Medicines | Name in `.bodyStrong`, directions in `.secondary` `ink`. `Bidi.auto` on each. Split at the first colon, as the web does |
| Primary | `complete.home`. `complete.history` quiet |
| Native | `StarRating`: five 44 pt targets, `star` and `star.fill` in `ink`, `.select` haptic. Live Activity ends. `.visitComplete` haptic once |
| No medicines | `complete.noMedicines` in `.secondary` `muted` |
| Rating sent | Read-only stars, `complete.thanks`, `5/5` isolated |
| Rating failed | `.secondary` `negative` line. `already_rated` refetches |
| Final ticket | `.caption` `muted`, number isolated. No hue, since the visit is over |

### S12 History

Question: what visits have I had?

| Field | Spec |
| --- | --- |
| On it | `history.title`. Flush `Card` of `ListRow`s: centre or `history.noCentre`, then date, service and dependent joined by ` · `. Status pill. Chevron on rows that open |
| Primary | None with rows |
| Native | Push, `.refreshable` |
| Rows | Completed positive, emergency negative, expired warning, others neutral. Completed opens S11. Emergency, refill, expired and cancelled rows do not open |
| Empty | `history.empty` in `.body` `muted`, then `home.start` primary |
| Loading | Card-sized bar |
| Error | `ErrorBlock` with retry |

### Settings

Question: which language and which clinic?

| Field | Spec |
| --- | --- |
| On it | `settings.title`. Section `settings.language`: `.segmented`, العربية and English. Section `settings.mode`: `.segmented`, `settings.mode.local` and `settings.mode.server`. Server section, only in that mode. Section `settings.demo`: reset, and `settings.notReviewed` in `.secondary` |
| Hierarchy | Sections are cards with a `.section` heading above. Not `Form`, which would change shape between systems and lose the footer |
| Primary | `settings.connect`, only in Clinic server mode |
| Native | Push from S01 and S03, `.segmented`, `.confirmationDialog` for reset. Each control saves itself |
| Server field | `settings.server`, `.keyboardType(.URL)`, no autocorrect, left to right. Sample `http://192.168.1.20:8100` |
| Connecting | Spinner in the button, reading `/api/health` only |
| Connected | `Pill` positive, `settings.server.ok` |
| Refused host | `settings.server.refusedHost` under the field in `negative`, before any request. Any host ending in `hf.space` or `huggingface.co` |
| Refused mode | `settings.server.refusedAi` under the field, when `ai_mode` is not `simulated` |
| Unreachable | `settings.server.unreachable` |
| Limit, always shown in this mode | `settings.server.limit` as a `Notice` |
| Reset | `settings.reset`, `DestructiveButtonStyle`, confirmed, On this phone mode only |

## 9. Live Activity and Dynamic Island

Starts when the ticket is active, never while reserved, because a reserved ticket has no number. Never on an emergency or refill visit. Local updates only, no push. Clinic server mode updates only while the app runs, so set a `staleDate`. Ends at visit complete with dismissal after 15 minutes.

The extension does not know the in-app language, so it reads `TicketActivityAttributes.lang`, sets `\.layoutDirection` and `\.locale` from it, and resolves labels through `Strings.bundled`. `TicketLiveState` already has `number`, `stage`, `peopleAhead`, `estWaitMin` and `counter`. These layouts also need two fields it lacks: the ticket state (active, called, serving) and the centre name. `number` stays nil only between stages here, since no activity runs while reserved.

Colours in the extension come from the shared hex table, resolved for the current scheme on the Lock Screen. On the Island they are always the dark values, because the Island is always black.

| Foreground | Hex | On `#000000` |
| --- | --- | --- |
| `ink` dark | `#f4f4f5` | 19.11 |
| `muted` dark | `#a6a7ac` | 8.74 |
| `hue` dark | `#689ce8` | 7.51 |

The number and current stage are the only hue. `keylineTint` is `ink` dark. Every digit is mono. Number text is always `Bidi.ltr`.

| Presentation | Layout |
| --- | --- |
| Lock Screen, 160 pt max, padding 14 and 16, opaque `activityBackgroundTint(surface)`, `activitySystemActionForegroundColor(ink)` | Row 1: centre name, `.caption`, `muted`, one line. Row 2: number at 44 pt semibold `hue`, scale to 0.5, leading; two stats trailing, value `.statValue`, label `.caption` `muted`: `ticket.peopleAhead`, `ticket.estimatedWait`. Row 3: `StageTrack(.compact)`. Row 4: `footer.demo`, `.caption2`, `muted`, one line, scale to 0.8. Rows 6 apart. About 153 pt. Above text size `.large`, drop Row 1 to stay under 160 |
| Compact leading | Number, `.caption` semibold mono, `hue`, one line, scale to 0.7 |
| Compact trailing | Active: `12 min`, `.caption` semibold, `ink`. Called: `live.go`. Serving: stage name. Missing: `–` |
| Minimal | Last three digits of the number, `.caption2` semibold mono, `hue`: `014`. No number: `clock`, `ink` |
| Expanded leading | Number, `.title2` semibold `hue`, then the stage name in `.caption` `hue` |
| Expanded trailing | Wait as `.title3` semibold, then `live.ahead` in `.caption` `muted` |
| Expanded center | Centre name, `.caption`, `muted`, one line |
| Expanded bottom | `StageTrack(.compact)`, then `footer.demo` in `.caption2` |

| State | Change |
| --- | --- |
| Active | As above |
| Called | Stats become `ticket.goNow` in `.section` `ink`. Update with a local `AlertConfiguration` so the Island expands |
| Serving | Stats become `ticket.withTeam` |
| Between stages | Number replaced by `ticket.nextStep` |
| Stale | `context.isStale`: number stays, stats in `muted`, plus `ticket.slower` in place of Row 1 |
| Ended | `complete.title` with `checkmark`, no number |

Limits: `.dynamicTypeSize(...DynamicTypeSize.xLarge)`, `lineLimit(1)` throughout. All four Island regions and the Lock Screen must exist even as Phase 1 placeholders. Number transitions use `.contentTransition(.numericText())`, and the system handles Reduce Motion here. `footer.ai` is left out, because nothing here is AI output.

Local notifications use `notify.next` and `notify.stage`, with the system default sound. In On this phone mode they are scheduled ahead. Clinic server mode states the limit in Settings.

## 10. App icon

Source: `frontend/public/icons/icon-512.png`, 512 by 512, no alpha. Measured: ground `#f2f4f7`, ink `#0a0a0a`, wordmark bounds x 103 to 408, y 204 to 355, so 306 by 152 px, 59.8% of the width, centred at (255.5, 279.5). The optical drop of 23.5 px is kept, because the descender of ي hangs below the word.

| Variant | File | Background | Wordmark |
| --- | --- | --- | --- |
| Light | `AppIcon.png` | `#f2f4f7` | `#0a0a0a` |
| Dark | `AppIcon-Dark.png` | `#101113` | `#f4f4f5` |
| Tinted | `AppIcon-Tinted.png` | `#000000` | `#ffffff` |

| Rule | Detail |
| --- | --- |
| Method | `ios/Tools/make-icon.swift` builds a mask from the source: `mask = (groundLuma - pixelLuma) / (groundLuma - inkLuma)`, clamped. Resample to 4x icon size, 4096 by 4096, in high quality with Core Graphics, sharpen there with `smoothstep(0.25, 0.75, mask)` so the edges stay clean, average each 4 by 4 block down to 1024, then `pixel = background × (1 - mask) + wordmark × mask` |
| Output | 1024 by 1024, RGB, no alpha, in all three. `sips -g hasAlpha` says no |
| Placement | Same relative size and position as the source. Rounding is the system's. No mask of ours |
| Forbidden | Hue, gradient, tile, gloss, shadow, border, or any second mark. The tinted file holds only greys, so the system's tint works |
| Catalog | One `AppIcon` set, single size 1024, with `luminosity` appearances `dark` and `tinted` |
| Also writes | `Wordmark` imageset: same mask as alpha over black, 612 by 304 px, `template` rendering. This is the S01 mark, so it is never redrawn or retyped |

## 11. Screenshot review checklist

Apply to any screen, in each of eight combinations: AR and EN, light and dark, default and AX3. Judge the picture, not the code. Any fail is a real fail.

| # | Check | Where |
| --- | --- | --- |
| 1 | Ground and card colours match section 1. Not system grey or white | All |
| 2 | The hue appears only on the patient's own number and current stage. S01 has none. No blue chrome, back chevron, cursor or link | All |
| 3 | Full red only on S06. Elsewhere, red is thin text or a pale pill | All |
| 4 | No emoji, gradient, violet, indigo, glow, shadow on a resting surface, or custom glass or blur | All |
| 5 | Product is named, in the bar or as the lockup | All |
| 6 | `footer.demo` and `footer.ai` are present, in this language, or reachable by scrolling on a long screen | All |
| 7 | One primary button at most. The biggest thing answers the screen's question | All |
| 8 | Nothing clipped, truncated or overlapping. Text wraps | AX3 especially |
| 9 | Arabic is right-aligned and full RTL, with letters joined. No tracking gaps. Marks intact | AR |
| 10 | Back on the right, chevrons point the correct way, toggle top left, stage track starts on the right | AR |
| 11 | Digits are Latin. `T-014`, QIDs, `999`, clocks read left to right, with no stray punctuation | AR |
| 12 | Figures align on one trailing edge, and digits do not jitter | All |
| 13 | Text passes contrast, including the footer. Field edges can be seen | All |
| 14 | Dark looks designed: steps of lightness, no pure inversion, hue legible on a card | Dark |
| 15 | Every target at least 44 pt | All |
| 16 | Layout adapts at AX3 as in section 3.4 | AX3 |
| 17 | Missing value is a dash, zero is a zero | Data screens |
| 18 | Wording: `Check-in valid for 45 minutes`. A reserved ticket shows no number or place. No no-show claim. No claim of PHCC or HMC connection, or of clinical review | All |
| 19 | S06: Call 999 is visible and pinned, white status bar, no back | S06 |
| 20 | S10: number fills the card, no clipping for `D-GP-023` | S10 |
| 21 | Screen matches its section 8 entry | All |

Screenshots cover what they can. Motion, haptics, VoiceOver order, Reduce Motion and the iOS 18 look need a run, a test or code reading. A screenshot pass is not a pass on those.

## 12. Swift names

These are the exact names. The app target holds them in `ios/Dawri/Design/`. The hex table goes in `ios/DawriCore/Sources/DawriCore/Design/`, so the Live Activity and the contrast test read the same values.

`DS.Type` cannot exist: Swift refuses a nested type named `Type`, checked with `swiftc` ("type member must not be named 'Type'"). The role type is `DS.TextRole`. All other API named here passed `swiftc -typecheck` for `arm64-apple-ios18.0-simulator` in Swift 6 mode, against SDK 27.2. That checks that the names exist, not how they behave at run time.

### Tokens

| Group | Names |
| --- | --- |
| DawriCore | `public struct DSHex { light, dark, lightHigh, darkHigh: UInt32 }`, `public enum DSPalette` with one static per token in section 1 |
| `DS.Color` | `ground`, `surface`, `raised`, `skeleton`, `hairline`, `rule`, `control`, `ink`, `muted`, `primaryFill`, `primaryPressed`, `primaryText`, `disabledFill`, `disabledText`, `hue`, `positive`, `negative`, `warning`, `pillPositiveFill`, `pillPositiveText`, `pillNegativeFill`, `pillNegativeText`, `pillWarningFill`, `pillWarningText`, `pillNeutralFill`, `pillNeutralText`, `noticeFill`, `noticeEdge`, `noticeText` |
| `DS.Emergency` | `field`, `pressed`, `text`, `callFill`, `callText`, `callPressed`, `card`, `cardText`, `cardMuted`, `link`, which are `emergencyField` and so on in section 1. Theme-independent: only `colorSchemeContrast` changes them, through section 1.3 |
| `DS.TextRole` | `barTitle`, `screenTitle`, `emergencyTitle`, `lead`, `urgent`, `section`, `body`, `bodyStrong`, `secondary`, `secondaryStrong`, `label`, `caption`, `pill`, `button`, `callButton`, `statValue`, `countdown`, `badge`, `ticketNumber` |
| `DS.Space` | `xxs` 2, `xs` 4, `s` 8, `m` 12, `l` 16, `xl` 24, `xxl` 32 |
| `DS.Radius` | `card` 8, `control` 6 |
| `DS.Stroke` | `edge` 1, `focus` 2 |
| `DS.Size` | `minTarget` 44, `button` 50, `buttonLarge` 56, `field` 48, `row` 44, `rowTwoLine` 56, `markWidth` 132, `markHeight` 66, `stageDot` 12, `stageDotCompact` 8 |
| `DS.Motion` | `push`, `sheet`, `press`, `release`, `stage`, `number`, `crossfade`. `DS.Motion.resolved(_:reduceMotion:)` returns `crossfade` when reduced |
| `DS.Haptic` | `stageChange`, `called`, `visitComplete`, `activated`, `failed`, `sent`, `micStart`, `micStop`, `select`, `scanned`, as `SensoryFeedback`, plus `static func emergency()` |

Inside `enum DS`, `Color` means `DS.Color`, so write `SwiftUI.Color` in that file.

### View helpers

| Name | Use |
| --- | --- |
| `Text.dsText(_ role: DS.TextRole)`, and `View.dsText(_:)` | Font, Arabic line spacing, digits. The only way to set type |
| `\.lang` | Environment value of DawriCore's `Lang`, set at the root from `LanguageState.lang`. `dsText` and `Bidi` callers read it |
| `Bidi.ltr(_:)`, `Bidi.auto(_:)`, `Bidi.fill(_:_:)`, `Bidi.strip(_:)` | Section 7.3 |
| `formatDate(_:lang:)`, `nameOf`, `centreName`, `checkInRoute` | Already in DawriCore. Reuse, do not re-port |
| `Measure(value:, unit:)` | Isolated figure, then the unit in the language. Port of `Measure` in `Values.tsx` |

### Components

| Name | Signature sketch |
| --- | --- |
| `PatientScaffold` | `PatientScaffold(title:, showsProductTitle:, tone:, footer:, @ViewBuilder content:)`, with `tone: ScaffoldTone` (`.default`, `.emergency`) and `footer: FooterMode` (`.flow`, `.pinned`) |
| `PatientFooter` | `PatientFooter(tone:)` |
| `LanguageToggle` | `LanguageToggle(tone:)` |
| `ProductLockup`, `ScreenTitle` | No configuration, and `ScreenTitle(_:)` |
| `PrimaryButtonStyle`, `SecondaryButtonStyle`, `DestructiveButtonStyle`, `QuietButtonStyle`, `EmergencyCallButtonStyle`, `ChipButtonStyle` | `ButtonStyle`. `isLoading` through `.dsLoading(_:)` |
| `Card` | `Card(flush:) { }` |
| `ListRow` | `ListRow(title:, subtitle:, pill:, showsChevron:)` |
| `KeyValueRow` | `KeyValueRow(label:, value:, style:)` |
| `Pill`, `PillTone` | `Pill(_:, tone:)`, with `.positive`, `.negative`, `.warning`, `.neutral` |
| `Notice`, `ErrorBlock`, `SkeletonBar`, `Dash` | `Notice(_:)`, `ErrorBlock(message:, retry:)`, `SkeletonBar(width:, height:)`, `Dash()` |
| `DSTextField` | `DSTextField(label:, text:, hint:, error:, kind:)`, with `kind: .plain`, `.qid`, `.code`, `.address` |
| `StageTrack`, `TrackStyle` | `StageTrack(stage:, style:)`, with `.full`, `.compact` |
| `TicketNumberBlock` | `TicketNumberBlock(number:, stage:)` |
| `CountdownText` | `CountdownText(expiresAt:)` |
| `WaitBadge` | `WaitBadge(minutes:, selected:)` |
| `ChatBubble`, `ThinkingBubble`, `SummaryCard` | `ChatBubble(role:, text:)` |
| `Composer`, `ListeningPanel`, `TranscriptConfirmPanel` | Section 4.8 |
| `StarRating` | `StarRating(rating:, onRate:)` |
| `DemoNextStepButton` | S10 only |
| `ChipFlow` | A `Layout` that wraps chips |
| `ComponentGallery` | The DEBUG screen behind `-demoScreen gallery`, showing every component in this list |

### Phone-only string keys

New keys the design needs, for `ios/Tools/strings/ios.en.json` and `ios.ar.json`. Keys already in those files are kept as they are, and are marked with a dash. The strings owner may adjust the Arabic of the new ones. Web keys are reused unchanged.

| Key | English | Arabic |
| --- | --- | --- |
| `settings.title`, `settings.language`, `settings.mode`, `settings.mode.local`, `settings.mode.server`, `settings.server` | Exists | - |
| `settings.connect` | Connect | اتصال |
| `settings.server.ok` | Connected, simulated mode | متصل، وضع المحاكاة |
| `settings.server.refusedHost` | This app does not connect to that host. | لا يتصل هذا التطبيق بهذا العنوان. |
| `settings.server.refusedAi` | This server is not in simulated mode, so the app will not use it. | هذا الخادم ليس في وضع المحاكاة، لذلك لن يستخدمه التطبيق. |
| `settings.server.unreachable` | We could not reach this server. | تعذر الوصول إلى هذا الخادم. |
| `settings.server.limit` | With a clinic server, updates arrive only while the app is running. | مع خادم العيادة، تصل التحديثات فقط أثناء تشغيل التطبيق. |
| `settings.reset` | Reset demo data | إعادة ضبط البيانات التجريبية |
| `settings.notReviewed` | The emergency rules have not been reviewed by a clinician. | لم يراجع أي طبيب قواعد الطوارئ بعد. |
| `settings.demo` | Demo | تجريبي |
| `reserved.scan` | Scan the door code | امسح رمز الباب |
| `reserved.codeLabel` | Door code | رمز الباب |
| `reserved.codeSubmit` | Check in | سجّل الوصول |
| `demo.nextStep` | Demo: next step | تجريبي: الخطوة التالية |
| `track.stepOf` | step {step} of {total} | الخطوة {step} من {total} |
| `voice.unavailableOnDevice` | Voice is not available on this phone. Please type your message. | الصوت غير متاح على هذا الهاتف. يرجى كتابة رسالتك. |
| `live.ahead` | {count} ahead | {count} أمامك |
| `live.go` | Go now | توجه الآن |
| `notify.next` | You are next | أنت التالي |
| `notify.stage` | Your next step is ready | خطوتك التالية جاهزة |
| `demo.waiting` | Demo: nothing moved, someone is ahead of you. | تجريبي: لم يتغير شيء، يوجد شخص قبلك. |
| `centre.mapPlaceholder` | The map is not ready yet. Use the list. | الخريطة غير جاهزة بعد. استخدم القائمة. |
| `common.loading` | Loading | جارٍ التحميل |
| `common.cancel` | Cancel | إلغاء |
| `settings.resetConfirm` | This clears the visits on this phone. | سيؤدي هذا إلى مسح الزيارات على هذا الهاتف. |

## 13. Coverage

| Screens.md entry | Section 8 |
| --- | --- |
| S01 | S01, no states listed |
| S02 error, loading | S02 |
| S03 no visit, active visit | S03 |
| S04 | S04 |
| S05 listening, thinking, error-retry | S05 |
| S06 | S06 |
| S07 | S07 |
| S08 loading, no services | S08 |
| S09 reserved, expired | S09 |
| S10 triage, doctor, pharmacy | S10 |
| S11 | S11 |
| S12 empty | S12 |
| Brief: consent | Consent |
| Brief: Settings | Settings |

Related: [[iOS Brief]] · [[Build Decisions]] · [[Screens]] · [[iOS Build Log]]
