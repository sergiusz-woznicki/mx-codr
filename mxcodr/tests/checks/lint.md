# lint -- the project's own rules (`mxcli lint`, `.claude/lint-rules/`)

One line per code the `lint` and `folders` steps can print. Every code blocks DONE unless its line
says "warning". The finding already says what to change; this says why. Not `tests/gate/*.sh`.

| Code | Wants | Fix |
|---|---|---|
| `UI001` | a data grid filters itself | one filter in the column (`textfilter`, `numberfilter`, `datefilter`, `dropdownfilter`, for an association `(Association: ..., datasource: database ..., CaptionAttribute: ...)`); never a filter bar over a helper entity |
| `MOD001` | documents in process folders, not at module root or in a folder named after a type (warning; `FOLDER01` below blocks the same) | `move microflow <Mod>.<Name> to folder '<Process>/FNC'` (skill `module-structure`) |
| `FOLDER01` | each document in `<business folder>/UI` (pages, snippets), `/FNC` (microflows, nanoflows) or `/ENV` (everything else); what the module shares in `_Shared/<kind>` | the `move ... to folder` lines given, all in one script; new documents with `create ... folder 'Orders/FNC'` |
| `REU001` | shared documents shared for real (info, never blocks) | a snippet used by one page is a page section; a `SUB_` with one caller is inline logic (skill `reuse-and-snippets`) |
| `MPR*`, `SEC*`, `CONV*`, `ARCH*`, `QUAL*` | mxcli's built-in rules; errors block, warnings do not | `./mxcli lint -p <app>.mpr --list-rules` names each |
| `CONV011` | a commit inside a loop: one database call per row (warning) | change the objects in the loop, `commit $List;` once after `end loop;`; new objects are `add`ed to a list first |
