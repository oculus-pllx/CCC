# SSH Key Inventory Settings Page Design

## Goal

Move the existing SSH Key Inventory from the Projects page to its own page in
the Settings navigation group while preserving the current GUI, theme, and
inventory behavior.

## Scope

- Add an `SSH Key Inventory` navigation button under the existing Settings
  heading.
- Add a dedicated client-side section with the page title
  `SSH Key Inventory`.
- Render the existing expandable inventory panel on that page.
- Remove the inventory placeholder and loading step from the Projects page.
- Update UI regression tests and user documentation to reflect the new
  location.

## Non-Goals

- No changes to the `/api/ssh-key-operation` backend endpoint.
- No changes to key discovery, ownership reporting, key type reporting, modified
  dates, unmanaged-key detection, confirmation prompts, or deletion behavior.
- No changes to per-project SSH key generation, test-host configuration,
  deployment, connection, or project SSH panels.
- No visual redesign, new theme rules, or unrelated navigation changes.

## Client Architecture

The new section will follow the existing single-page navigation pattern:

1. Add a section identifier for the inventory page to the Settings navigation.
2. Register its title and renderer in `app.js`.
3. Render a placeholder using the existing panel layout.
4. On section binding, load keys through the existing
   `loadSSHKeyInventory()` function.
5. Replace the placeholder with `renderSSHKeyInventory(keys)` and attach the
   existing `bindSSHKeyInventory()` handlers.

The Projects renderer and binder will no longer create or load the system-wide
inventory. Their project management and per-project SSH behavior will remain
unchanged.

## User Interface

The Settings navigation group will contain a new `SSH Key Inventory` entry.
Selecting it will display a page titled `SSH Key Inventory`.

The page will retain the current:

- Expandable header and arrow indicator
- Total and unmanaged key summary
- Path, owner, type, modified date, and action columns
- Unmanaged-key warning styling
- Delete button and confirmation dialog
- Empty inventory message

Existing CSS classes will be reused so the page continues to follow the active
CCC theme and responsive layout.

## Data and Error Behavior

The page will continue to call the existing key-operation endpoint with the
`list-keys` action. Existing behavior for a failed inventory request remains an
empty inventory because changing error handling is outside this relocation.

Deleting a key will continue to use the `delete-key` action. After successful
deletion, only the inventory panel will refresh. Failed deletions will continue
to display the existing alert.

## Testing

Regression coverage will verify:

- The Settings navigation contains the new inventory section in the intended
  order.
- The Projects page no longer contains or loads the system-wide inventory.
- The dedicated section is registered with the correct title, renderer, and
  binder.
- Existing inventory rendering and action functions remain present.
- The existing static, JavaScript, and Go test suites pass.

## Documentation

The SSH Key Management guide will direct users to
`Settings > SSH Key Inventory` instead of the Projects page. Other SSH key
documentation remains unchanged.
