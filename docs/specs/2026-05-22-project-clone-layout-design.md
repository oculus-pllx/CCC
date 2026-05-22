# Project Clone Layout Design

Date: 2026-05-22
Status: Approved design, pending implementation plan

## Goal

Tighten the Projects clone controls so the repository import workflow reads as a
normal form action instead of a large button with mismatched fields, and make the
editable header message visibly editable from the main view.

## Scope

The change covers browser UI only:

- Projects clone-control layout and responsive behavior.
- A visible edit affordance beside the header message shown above each section.
- Client-side navigation/focus behavior for that edit affordance.
- Focused static or browser-side regression coverage for the new structure.

The change does not alter Git clone/pull backend behavior, project validation,
title storage, theme behavior, or the Preferences editor model.

## Projects Clone Layout

The existing Clone Repository action remains above the project list and keeps the
current fields:

- Repository URL
- Optional project/folder name
- Clone button

On desktop widths, these controls should share one aligned row:

- The repository URL field is the flexible wide control.
- The optional project-name field is shorter than the URL field.
- The Clone button uses the normal small action-button sizing instead of
stretching across the form.

On narrow/mobile widths, the controls should stack with usable field widths so a
long Git remote remains readable and tappable.

## Header Message Edit Affordance

The header message display should become a row containing:

- The current custom title text.
- A small `Edit` button aligned at the far right.

Clicking `Edit` should navigate to the existing Preferences view and focus the
Header Message input already used to edit the stored text. Editing remains
centralized in Preferences rather than introducing a second inline editor.

## Error Handling And Accessibility

- The new button should be a real button with an explicit type.
- Focusing the Preferences field should degrade safely if rendering changes and
  the field is not present.
- The header message text should continue to use the current display update path
  so stored title changes still appear immediately.

## Testing

Add targeted checks that prove:

- The Projects renderer exposes the clone controls with a dedicated row layout
  hook for CSS.
- The main page contains the header edit affordance.
- The client binds the edit affordance to Preferences navigation and field
  focus.

