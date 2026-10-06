---
name: film-tests
description: "Record a video of a browser test's run -- one test, several, or all of them -- with the test's name on the film, and list every test first so the person can choose. Use when someone asks to see, film, record or show a test, a journey, or how the app works."
---

# Film a test

`tests/film.sh` records the browser while a test runs, unchanged but slowed so it can be followed:
the pointer goes to each element before it is used, and a pause follows. Each film opens with a
card naming the test.

## Steps

1. **List the tests** and show the person the list, as it prints:

   ```bash
   bash tests/film.sh --list
   ```

   Each entry gives the test's name, the user it signs in as, what it covers and the journey in
   its own words. A test with no browser (API or OQL only) says "nothing to film".
2. **Ask which ones**, unless the request already names them: one, several, or all.
3. **Record:**

   ```bash
   bash tests/film.sh <name> [<name>...]    # e.g. bash tests/film.sh orders toasts
   bash tests/film.sh --all                 # every test with a browser, plus all.mp4
   bash tests/film.sh --pace 1500 orders    # slower still (ms per action; default 1000, 0 = test speed)
   ```

Each film has one page listing what the test did, step by step, in English (labels only, never
typed values). ffmpeg is optional: with it the page opens an `.mp4`; without it there is only the
`.webm`, with the page at its end. On a Mac `brew install ffmpeg` adds it, if the person wants mp4s.

4. **Give the paths** it prints: `.mxcli/films/<name>.mp4` (and `.webm`), `.mxcli/films/all.mp4`
   for `--all`. A failing test keeps its film, which shows where it stopped -- say that it failed.

## Rules

- **The app must be up.** If `film.sh` says no app answers, start it with
  `bash tests/gate.sh --boot-if-needed`, then film.
- **One browser for everything.** The tests and the gate share it: never film while a gate or a
  test runs (`film.sh` refuses), and never run the gate while filming.
- **Films are not committed.** They live under `.mxcli/films/`, which git ignores. Do not edit a
  test to make a better film; the film shows the test as it is.
