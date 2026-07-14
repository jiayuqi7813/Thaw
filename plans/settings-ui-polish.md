# Settings Header Correction and Restrained UI Polish

**Status: implemented**

## Summary

Correct the header regression before adding animations. Pane titles should be standalone large headings, not navigation/titlebar elements or native `Form` sections. Preserve the transparent titlebar, removed separator, correctly positioned sidebar search, existing content sections, full-pane glass, and rounded button shapes.

## Changes

- Render one shared pane heading in the detail host above the selected pane content.
- Keep `IceForm` limited to actual settings sections and remove About's special title handling.
- Preserve the detail-only safe-area treatment and the single full-pane Liquid Glass surface.
- Crossfade pane content and sidebar search modes with short opacity transitions.
- Fade Layout loading, timeout, reset confirmation, and status changes without directional motion.
- Disable About's pointer tilt under Reduce Motion and show temporary copy confirmation.

## Verification

- Confirm every pane has one standalone title with no card, section chrome, separator, or titlebar placeholder.
- Check sidebar search placement and normal, results, and empty transitions.
- Exercise Layout loading, timeout, reset confirmation, success, and error states.
- Test rapid pane switching and repeated version-copy activation.
- Repeat in light and dark appearances with Reduce Motion and Reduce Transparency enabled.
- Run SwiftLint and the unsigned test command when dependency resolution permits.

## Constraints

- Preserve unrelated dirty changes.
- Do not add more static glass layers or remove existing section cards.
- Do not change search architecture, result highlighting, visual-test infrastructure, or menu-bar divider animations.
