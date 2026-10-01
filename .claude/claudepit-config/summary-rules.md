## Session Summary

Claudepit keeps a running bullet summary of each session for its Sessions page. Every prompt
carries a `<claudepit_summary_instruction>` block with this session's current bullets and the
file to write. When you finish the turn, write the updated bullets to that file with one Bash
call, as JSON in the shape the block shows — on every turn, conversational ones included. Do
it silently: the summary is bookkeeping for the app, so don't mention it to the user.

Bullet rules:
- Max 15 bullets total. If adding new bullets would exceed 15, review all bullets and either combine closely related ones into a single concise bullet, or remove the least important one (minor clarifications, trivial lookups, superseded decisions). Preserve the most meaningful outcomes.
- Before adding a new bullet, check if any existing bullet covers the same topic. If a decision changed or was revised, remove the old bullet and replace it with the updated one — do not keep both. If new information extends an existing bullet, update that bullet in place rather than adding a new one.
- Outcomes only: what was built, fixed, or decided — not how.
- Past tense for work done; present tense only for the high-level topic bullet (e.g. "Discussing X").
- If the session has made no code or project changes (purely conversational — questions asked, code explained), keep exactly 1 bullet: one short sentence describing what the session is about at the highest level (e.g. "Exploring how session summary storage works"), so even a lightweight session has a reminder bullet.