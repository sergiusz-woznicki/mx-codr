# What each check code wants, and its fix

One file per gate step; the gate names the file for the step that failed. Read that file, not
`tests/gate/*.sh` or the checkers: the finding already says what to change, the file says why.
Every code blocks DONE unless its line says "warning".

| step | file | codes |
|---|---|---|
| layout | `tests/checks/layout.md` | NAV01, NAV02, NAV03, NAV04, NAV05, NAV06, HOME01, ACCOUNT01, ACCOUNT02, ACCOUNT03, MODULE01, USER01, BACK01, ICON01, LAYOUT01, EDGE01, SPACE01, SPACE02, SPACE03, SPACE04, GRID01, GRID02, ALERT01, TEXT01, TEXT02 |
| lint | `tests/checks/lint.md` | UI001, MOD001, REU001, MPR*, SEC*, CONV*, ARCH*, QUAL*, CONV011 |
| naming | `tests/checks/naming.md` | placeholder-variable, type-echo-variable, REFRESH01, PERF02-PERF08, action-caption, action-caption-is-default, decision-caption, caption-not-a-question, caption-restates-expression, loop-annotation, caption-on-loop |
| mx check, coverage, precheck, security, scope, the suite, visual and runtime | `tests/checks/app.md` | coverage, TEST01, SCRIPT01, security, VIEW01, SCOPE01, RUNTIME01, VIS01, VIS02, VIS03, VIS04, LOOK01, LOOK02, CE0582, CE0106, CE0557, CE0007, CE0117, CE0161, CE0642, CE1613, CE2729, CE7247, CE7247 |
