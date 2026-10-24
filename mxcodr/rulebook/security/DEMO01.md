---
step: security
level: block
check: security_rules.cjs#demo01
key: document
---

# DEMO01 — every role has a demo user

## What it checks
Demo users are on, and every user role of the app's own modules (the guest role aside) has at least one. They are how the person signs in as each role to try the app, and how the tests sign in. They sit beside real accounts and the login page: a request for real sign-in replaces a role picker the app built itself, never the demo users. Switching them off is the person's step before go-live (here, `level: off` under Local).

## Fix
`alter app security ( EnableDemoUsers: TRUE );`, then per role without one:
`create demo user 'demo_manager' ( Password: 'Manager1234!', Entity: Administration.Account, UserRoles: (Manager) );`
and `TEST_PASSWORD_demo_manager=Manager1234!` in `tests/credentials.env`.

## Local
# level: block
# except: Manager  # a role nobody signs in as directly
