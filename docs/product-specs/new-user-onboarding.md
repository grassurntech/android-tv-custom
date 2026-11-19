# New User Onboarding

> **Purpose:** Spec for the first-run / onboarding experience.
>
> **Last updated:** 2026-11-19

The onboarding is `PROMPT.md`, seen from the owner's side. About an hour, one sitting.

1. **Paste:** the owner opens `PROMPT.md`, copies it all and pastes it into their AI tool.
2. **Get the project and check the computer:** the AI clones the repo, checks Git, Python and Docker, and fetches the tools. Nothing on the TV changes yet.
3. **Connect:** the owner turns on developer mode and debugging and says the TV's IP. They accept "Allow debugging?" on the TV.
4. **Back up:** the AI saves the TV's state to `backups/` before any change.
5. **Clean up:** the AI proposes junk to switch off and the owner approves. Each is switched off one at a time.
6. **Home screen:** the owner picks photos, a name, a clock style and four apps. The launcher is built, installed and themed, then the TV restarts once.
7. **Finish:** the AI switches debugging off and shows how to undo (`restore`).

The AI summarises after every phase and waits for a yes. If anything goes wrong it stops and points to the undo.
