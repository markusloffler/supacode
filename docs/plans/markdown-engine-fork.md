# Plan: Typora-Faithful Spacing and Heading Rules via a swift-markdown-engine Fork

## Goal

Make the GitHub editor theme (`MarkdownEditorStyle.github`, derived from `theme/github.css`) match Typora in two places that `swift-markdown-engine` 0.15.0 cannot express:

1. **Vertical rhythm between blocks.** Typora turns the blank line between blocks into a CSS margin (`p` 0.8em, headings 1rem, collapsed to the larger one). The engine renders each blank line as a full body line (16 pt × 1.6 ≈ 26 pt). Above a heading it also adds `topSpacingEm`. The result is about 42 pt above a heading where Typora has 16 pt, and about 26 pt between paragraphs where Typora has 12.8 pt.
2. **Rule under h1/h2.** `border-bottom: 1px solid #eee` under h1 and h2. The engine has no configuration or extension hook for it.

## Non-goals

- Other CSS gaps listed in `MarkdownEditorStyle.github`'s doc comment (h6/blockquote colors, table/code borders, media queries). Possible follow-ups in the same fork.
- Changing the source text. The buffer stays byte-for-byte the file, so blank lines remain real lines. Only their rendering shrinks.

## Fork Setup

- Fork `nodes-app/swift-markdown-engine` on GitHub and branch `supacode` from tag `0.15.0`.
- Keep a working checkout under `~/loffler.local/programming/libs/swift-markdown-engine`, which is writable from the sandbox.
- `Tuist/Package.swift`: point the `// MARK: Markdown editor` dependency at the fork, pinned with `revision:` (not a branch) so builds stay reproducible. During development, temporarily use `.package(path:)` to the local checkout.
- Keep every engine change opt-in. Defaults reproduce 0.15.0 rendering exactly, so the `system` theme is unaffected and the patches stay upstreamable.
- Keep changes small and isolated (new config fields, one styling branch, one draw pass) to make rebasing onto newer upstream tags cheap. Track the patch list in the fork's README section "supacode patches".

## Engine Changes

### 1. Blank-line height

- `Configuration/MarkdownEditorConfiguration.swift`: add `ParagraphStyle.blankLineHeight: CGFloat?`. `nil` (default) keeps the current behavior.
- `Styling/MarkdownASTStyler.swift` `styleBlock`: the `.blank` case currently does nothing, so blank lines inherit the base paragraph style from `TextStylingService.makeBaseFontAndStyle`. When `blankLineHeight` is set, apply a paragraph style to the blank block's range with `minimumLineHeight = maximumLineHeight = blankLineHeight`, `paragraphSpacing = 0` and `paragraphSpacingBefore = 0`.
- Incremental restyle: verify that a line becoming blank (deleting its text) or a blank line receiving text gets restyled. That path is `NativeTextViewCoordinator+TextDelegate.swift` (`tokenRestyleParagraphs`, the blank-separator walk around line 351). Otherwise a stale short or tall line remains until the next full restyle.
- Caret: check that the caret on a shortened blank line is drawn at a sensible height and that clicking into it still places the caret there. If not, clamp the caret rect to the base font's line height in the text view's caret override.
- Consecutive blank lines each get the reduced height. This approximates Typora, which collapses them entirely.

### 2. Heading bottom rule

- Configuration: add `HeadingStyle.bottomRuleLevels: Set<Int>` (default empty), `bottomRuleSpacingEm: CGFloat` (gap between text and rule) and `MarkdownEditorTheme.headingRule: NSColor`.
- Styler (`styleBlock` `.heading`): for a configured level, tag the heading's paragraph range with a new attribute key `.headingRule` (next to `.thematicBreak` in `Renderer/MarkdownTextLayoutFragment.swift`). Add the gap plus rule width to the heading's `paragraphSpacing` so following text clears the rule.
- Renderer (`MarkdownTextLayoutFragment`): add `hasHeadingRule`, extend `renderingSurfaceBounds` like the thematic-break case, and add `drawHeadingRule(at:in:)` modeled on `drawThematicBreaks`. It draws a 1 px line across the container width (respecting text insets and reading width) below the fragment's last line.
- Wrapped headings: draw under the last line fragment only.

### 3. Tests (in the fork)

- Styler unit tests in `Tests/MarkdownEngineTests`: the blank range gets the fixed line height only when configured, the heading range carries `.headingRule` only for configured levels, and defaults are unchanged.

## Supacode Changes

`supacode/Features/Markdown/Views/MarkdownEditorStyle.swift`, `github` theme:

- `paragraph.blankLineHeight = round(0.8 * fontSize)`: the 0.8em `p` margin.
- `headings.topSpacingEm`: lower so that blank line plus top spacing ≈ 1rem (about `(16 - 12.8) / headingSize`, so near 0.1em for h1/h2). Tune against the Typora screenshot.
- `headings.bottomRuleLevels = [1, 2]`, `theme.headingRule = dynamic(light: hex(0xEEEEEE), dark: .separatorColor)`. h1/h2 `line-height` 1.2/1.225 also affects the space above the rule.
- Remove "heading rules under h1/h2" from the doc comment's list of unrepresentable features.
- `docs/plans/markdown-editor.md`: note the fork and its pin under "Library Choice".

## Also to Check (Not Spacing)

The editor screenshot appears to render in SF/Helvetica rather than Open Sans. Verify that the bundled `.woff2` fonts reach the app bundle and register (`MarkdownFonts.registerBundled` logs the count), and that the PostScript name is `OpenSans-Regular`. Otherwise all metrics above are computed for the wrong font.

## Verification

- Build via `sbuild` (scheme `supacode`, destination `mac`).
- Open the same `CLAUDE.md` in read mode next to Typora and compare the gaps around paragraphs, headings and lists, and the rules under h1/h2, in light and dark appearance.
- Edit mode: type into and delete blank lines between blocks and check for layout jumps, stale heights and caret placement.
- The `system` theme looks unchanged.

## Risks

- TextKit 2 incremental layout may cache fragment heights. A blank line flipping height on edit needs invalidation, which is the main source of possible bugs.
- Every upstream engine update now needs a rebase of the fork.
