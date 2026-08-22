# README: Remove Contributing and Support sections

## Problem

The README ends with a **Support** section (star the repo, GitHub Sponsors, Ko-fi) that does not fit `kns`: a small personal bash/zsh kubectl helper under MIT, not a funded product. A placeholder **Contributing** section (`[Add contribution guidelines here]`) sits above it and is equally unhelpful.

## Decision

Remove both sections. Leave **License** as the final README section.

## Scope

### In scope

- Delete the entire `## Contributing` block (heading + placeholder text).
- Delete the entire `## Support` block (heading, star/Sponsors/Ko-fi bullets, thank-you line).
- Ensure the README ends cleanly after the License section (no orphan blank lines beyond normal file ending).

### Out of scope

- Other README edits (install typos, feature polish, emoji cleanup).
- Writing real contribution guidelines.
- Changing GitHub Sponsors / Ko-fi account setup or repo About metadata.
- Code or installer changes.

## Approach

Surgical delete only — minimal diff, no replacement footer or contribution one-liner.

## Success criteria

- README has no Contributing or Support sections.
- License remains the last section.
- No other intentional content changes in this change set.
