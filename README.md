# SoFlo Wheelie Life

A single-file HTML5 canvas wheelie game. No build step, no dependencies —
just `index.html`.

## Run locally

Open `index.html` in a browser, or serve it:

```bash
python3 -m http.server 8000
```

## Deploy

Pushes to `main` deploy automatically to Vercel.

## Player saves

Progress lives in `localStorage` under the key `soflo.save`, so it survives
updates to the game. Two rules keep it that way:

1. **Never change the origin.** localStorage is per-domain. Players on the
   custom domain and players on `*.vercel.app` have separate saves.
2. **Only add fields to `SAVE`, never rename or remove them.** The loader
   merges an old save onto the current defaults, so new fields fill in
   automatically for returning players. Renaming a field silently wipes
   that piece of everyone's progress.
