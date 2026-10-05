# naming -- microflows and nanoflows (`check_mdl.cjs --skill naming`, skill `naming-and-captions`)

One line per code the `naming` step can print. Every code blocks DONE unless its line
says "warning". The finding already says what to change; this says why. Not `tests/gate/*.sh`.

| Code | Wants | Fix |
|---|---|---|
| `placeholder-variable` | a name that says what it holds | `$OpenInvoiceCount`, not `$Int1`, `$tmp`, `$x` |
| `type-echo-variable` | no `_List`, `_Object`, `_Obj` suffix | `$OverdueInvoices`, not `$Invoice_List` |
| `REFRESH01` | a microflow that closes its page (a popup's Save) commits with `refresh`, so the grid under the popup shows the new row at once | `commit $Invoice refresh;`, `change $Invoice (...) commit refresh;` -- blocks DONE |
| `PERF02` | a loop over a retrieved list only adds up its rows (warning) | an OQL view entity computes totals in one query; `count()`/`sum()` after the retrieve is no faster |
| `PERF03` | a database call per row in such a loop: a retrieve, a Java action, a flow that reads or writes (warning) | one retrieve before the loop (XPath over the association), or an OQL view |
| `PERF05` | a whole table retrieved, then rows kept with an `if` (warning) | the condition in the retrieve's XPath |
| `PERF06` | a loop that only keeps the largest or smallest value (warning) | `retrieve $Last from M.E where [...] sort by M.E.Attr desc first;` |
| `PERF07` | a retrieve, page source, grid filter or view no index serves (warning) | the line it prints: `alter entity M.E add index if not exists (A, B);`, `=` columns first; a query along an association needs none |
| `PERF08` | an index no query in the model needs (warning) | the `drop index if exists (...)` it prints, spelled as written; keep it if Java, other OQL or an outside client filters on it |
| `action-caption`, `action-caption-is-default`, `decision-caption`, `caption-not-a-question`, `caption-restates-expression`, `loop-annotation`, `caption-on-loop` | a business `@caption` on every action and decision (a question, no `$`), `@annotation` on loops | warnings while the app is built; after the first DONE a microflow new or changed since the last DONE needs them (blocks), older ones stay warnings; `MDL_CAPTIONS=error` makes all block |
