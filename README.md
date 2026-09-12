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

## Accounts and the live systems

Accounts, the leaderboard, crews, announcements, events, chat and polls all run
on Supabase and are set up by the SQL files in this directory. See
[CLOUD-SAVES.md](CLOUD-SAVES.md) for what each one adds and which order to run
them in. The game plays fine with none of them: leave `CLOUD.url` and
`CLOUD.key` blank and it is a local game with a local save.

## Getting around

Five tabs, fixed to the bottom of the screen on every menu: **Play**, **Garage**,
**Chat**, **Ranks**, **Account**. The bar hides itself while you are riding,
where the HUD and the touch controls own the bottom of the screen.

Account is where everything about *you* lives — who you are signed in as, the
season pass, rebirth, the second world, your profile and your crew — so Play
is just the modes, the daily, the crate and whatever is live.

## Player saves

Progress lives in `localStorage` under the key `soflo.save`, so it survives
updates to the game. Two rules keep it that way:

1. **Never change the origin.** localStorage is per-domain. Players on the
   custom domain and players on `*.vercel.app` have separate saves.
2. **Only add fields to `SAVE`, never rename or remove them.** The loader
   merges an old save onto the current defaults, so new fields fill in
   automatically for returning players. Renaming a field silently wipes
   that piece of everyone's progress.

The one thing that deliberately lives outside `SAVE` is the ghost lap, under
`soflo.ghost`. It is a few thousand coordinates, it is per device, and it
rebuilds itself on your next good run — none of which is worth pushing to the
server on every sync or writing merge rules for.
