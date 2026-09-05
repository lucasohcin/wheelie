# SoFlo Wheelie Life — handoff

Everything a fresh session needs to pick this up. Written 3 Sep 2026.

---

## What this is

A wheelie game. One file: **`index.html`**, ~8,000 lines, no build step, no
dependencies. HTML + CSS + one big IIFE of JavaScript, rendered to a canvas.

- **Repo:** https://github.com/lucasohcin/wheelie
- **Deploy:** Vercel, auto-deploys on push to `main`. `vercel.json` disables
  caching on the HTML so players always get the newest build.
- **Backend:** Supabase (accounts, saves, leaderboard, crews, admin).

Owner is `lucasohcin` / "Not wet studio". Players so far are the owner and a
small group of friends.

---

## Read this before touching the code

### It is one IIFE

The whole script is wrapped in `(function(){ ... })();`. Nothing is global.
That is good practice and it makes testing awkward — see **Testing** below.

### Temporal dead zone will bite you

This has caused **three separate bugs**, one of which shipped:

- `resize()` runs at startup, before `const LAYERS` is declared
- `normaliseSave()` runs at load, before the XP/season constants exist
- the VERSUS block read `S` before `S` was declared

**Rule: if a function runs during module init (load, resize, normaliseSave),
every constant it touches must be declared above it.** `typeof X` does *not*
protect you from a TDZ `const` — it throws.

### Never break saves

Progress lives in `localStorage` under `soflo.save`, mirrored to Supabase.
`normaliseSave()` merges an old save onto current defaults and repairs missing
fields, so **adding** fields is free.

- **Add fields freely.** Never rename or remove one — that silently wipes that
  piece of every player's progress.
- Bike indexes are positional. **Append new bikes; never reorder `BIKES`.**
- `PRICES` is index-aligned with `BIKES`. Pad it when you append.

### Do not run two Claude sessions on this repo at once

It happened on 3 Sep: a second session committed the same feature concurrently
(`30d9ab4`). Nothing was lost that time, by luck. Two sessions editing a single
8,000-line file will overwrite each other.

---

## Architecture

| Concern | Where |
|---|---|
| Physics tick (street/ride out) | `tickStreet()` — 30 Hz fixed step |
| Ramp physics | `tickRamp()` |
| Scene render | `renderStreet()` / `drawScene()` / `renderRamp()` |
| Bike stats pipeline | `buildBike(idx)` → `CUR`, read via `bike()` |
| Save repair on load | `normaliseSave()` |
| Cross-device merge | `mergeSaves(a, b)` |
| Cloud sync | `cloudSyncNow()` |
| Two-player | `startVersus()` / `vsTick()` / `vsRender()` / `renderVersus()` |
| Daily seed run | `startDaily()` / `dailyFinish()` / `dailyStop()`, plan in `dailyPlan(day)` |
| Rider profiles | `openProfile(name, from)` / `profileFetch()` / `renderProfile()` / `profilePush()` |
| Rivals | `rivalFetch()` on run start, `rivalCheck(live)` once a frame, `drawRival()` in both HUDs |
| Badges | `BADGES` catalogue, `badgeCheck()` on every `persist()`, case in `renderProfileCase()` |
| Weather | `WEATHERS`, `weather()`, `windNow()`, `drawWeather()` in both renderers |
| Time trial | `startTrial()` / `ttTick()` / `ttFinish()`, course from `ttPlan(week)` |

**Stat pipeline order:** base bike → upgrade pips → engine swap → fitted parts.
All multiplicative except `loop`/`bp`, which are additive offsets.

**Rendering:** static backdrop layers (sky, vignette, road wash, lamp glow) are
baked into offscreen canvases by `buildLayers()`, keyed on `spot|W|H`. Frame
time is watched by `tuneQuality()`, which steps render scale through
`Q_STEPS = [1, 1.25, 1.5, 2]`. Before this the game ran at 17–40 ms/frame; the
background alone was 84% of a frame.

**Daily seed run** is ramp mode with the randomness seeded. `tRnd` is the
terrain generator's source of random numbers; it is `Math.random` normally and
a `seedRnd(seed)` stream while `DAILY.on`. Everything about a day — the track,
the loaner bike, the terrain seed — falls out of `dailyPlan(day)`, so nothing
is stored anywhere and every rider computes the same setup independently. The
loaner is `buildBike(idx, DAILY_STOCK)`, which skips the player's upgrades.
`DAILY.on` also locks `rtrack()`, blocks `cycleBike()`, keeps the crash from
respawning at a checkpoint, and keeps the run out of `SAVE.rampBest`.

**Weather** is four conditions applied as multipliers at single points in each
tick: grip on acceleration and on the ramp's tyre grip, brake force, and a
gust added straight to the pitch velocity. Nothing about it can change a clear
run. You pick your own, because a record set in the rain against one set in
the dry is not a record; the daily picks its own off the seed so a day is the
same for everyone, and the time trial forces clear because it is a timed
board.
Two things worth knowing. The weather draw goes on the **end** of the daily's
seed stream, so every day already ridden keeps the bike, track and terrain it
had - a test pins day 243's whole plan, computed outside the game, to catch
anyone moving it. And `WEATHER_FROM_DAY` exists because day 244 was already
being ridden when weather was built: without it, half a board would have been
in the dry and half at night.
The weather clock `wxT` ticks with the physics, not the renderer, so a gust is
the same length of time on every machine.

**The time trial** is ramp physics on a course seeded off the **week** rather
than the day, because a time trial you only see once is a lottery. Style is
worth nothing; the clock starts when you move, three splits call out on the
way, a crash costs three seconds and puts you back at the last checkpoint
rather than ending the run. The loaner is stock, like the daily.
It is the only board in the game where the smallest number wins, which is why
`trials.sql` has a `least()` trigger where `scores` has a `greatest()` one,
and why `mergeSaves` takes the lower time per week rather than the higher.

**Badges** are predicates over the save, nothing more. `badgeCheck()` runs
inside `persist()`, which is every point at which the save changed in a way
worth writing down, so a badge cannot be missed by a code path that forgot to
call something and no new per-run tracking was needed - `SAVE.qp` was already
counting flips, air, hang time and the rest for quests.
Three rules for the catalogue: **append freely, never change an id** (it is
what a save and a pinned slot refer to), and **never delete one**, or you take
a badge off somebody who earned it. A predicate that throws is caught per
badge so one bad entry cannot cost you the rest.
A save made before badges existed qualifies for a pile at once, so the first
pass is a silent backfill with a single line rather than a wall of toasts.
That line is drawn by the riding HUD and most badges land while you are on the
menu, where it is invisible - which is why the menu's profile link carries the
count instead. Same lesson as the announcement bug: a message nobody is in a
position to see is not a message.

**Rivals** put a name on the number you are riding against: the handful of
riders sitting just above you on the board for the mode you are in, fetched
once when a run starts and walked up one at a time as you pass them. It adds
no table and stores nothing - it reads `scores` and `daily`, which were
already public - and every failure in it is swallowed, because a nicety must
never interrupt a run.
Two things there are easy to get wrong. A street crash banks the run and
resets the score to zero, so `rivalRebase()` re-points the chase at the first
rider still above your *new* record; without it you would silently skip
everyone. And a daily's baseline is zero rather than your record, because a
fresh attempt starts at the bottom of today's board and climbs it - which is
why `rivalRebase()` returns early for the daily instead of walking you back
down to last place.
The list is a snapshot taken when the run began. If somebody beats you while
you are riding, you will not see it until the next run; that is deliberate,
so the target cannot move under you mid-run.

**Rider profiles** are a public card per rider, opened by clicking a name on
any leaderboard or crew roster. The avatar is not an upload: it is their bike,
in their paint, drawn by the same `thumbBike()` the garage uses, from a bike
index and five colours on the row. Nothing needs hosting and nothing needs
moderating except the two fields a player types — display name and bio — which
are capped, stripped of control characters, and escaped on the way out.
`buildBike(idx, STOCK_TUNE)` is what makes an avatar show the bike rather than
the owner's upgrades; the daily loaner uses the same argument.
The username on a row is set by a database trigger off the account, never by
the client, because profiles are looked up by name and letting a client set it
would let one player claim another's name.

**Versus** swaps the module globals (`S`, `POSE`, `CUR`, `ctx`, `target`,
`SCALE/DPR/OFFX/OFFY`) around each rider, renders each to its own offscreen
canvas, and blits them into stacked halves. `S` is `let`, not `const`, for
exactly this reason. Always restore globals in a `finally`.

---

## Supabase

Project: `https://nsaruxhrgjukeilknbma.supabase.co`
Publishable key is in `CLOUD` at the top of the script — safe to ship, row
level security is what actually protects data.

**Never put the `service_role` key in the game.** It bypasses RLS.

| Table | Read | Write |
|---|---|---|
| `saves` | own row only | own row only |
| `scores` | public | own row only, scores monotonic (trigger) |
| `crews` | public | owner only |
| `crew_members` | public | own membership only |
| `crew_board` (view) | public | — |
| `admins` | own row only | dashboard only |
| `broadcasts` | public | admins only |
| `grants` | own + admins | insert admins, claim own |
| `daily` | public | own row only, **insert only** — no update policy, so one attempt a day is enforced by the database |
| `profiles` | public | own row only, plus `is_admin()` for taking a bio down. `badges` / `badge_count` were added later; re-run `profiles.sql` for them |
| `trials` | public | own row only, and a trigger that only ever lets a time come down |

SQL lives in `supabase-setup.sql`, `leaderboard.sql`, `crews.sql`, `admin.sql`,
`daily.sql`, `profiles.sql`, `trials.sql`.
All are idempotent — safe to re-run.

**Auth quirk:** usernames map to internal addresses `name@wheelie.local`, which
cannot receive mail. The project therefore **requires** Email provider ON and
Confirm email OFF. If signups break, check those two toggles first.

**Verify security from the shell** — anonymous writes must be refused:

```bash
curl -s -X POST -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d '{"message":"test"}' "$URL/rest/v1/broadcasts"
# expect: 42501 row-level security violation
```

---

## Features and their tuning knobs

| Feature | Key constants |
|---|---|
| Rider levels | `XP_BASE 320`, `XP_STEP 190`, `MAX_LEVEL 60` |
| Season pass | `SEASON_START`, `SEASON_DAYS 42`, `SEASON_TIERS 30`, `SEASON_XP_PER_TIER 900`, `PASS_PRICE 60000` |
| Crews | `CREW_PRICE 50000`, `CREW_BONUS 1.5` |
| Style chain | `STYLE_STEP 2200`, `STYLE_GRACE 12`, `STYLE_CRASH_KEEP 0.34` |
| Render quality | `Q_STEPS` |
| Admin door | `ADMIN_PHRASE "adminabuse"` |
| Daily seed run | `DAILY_EPOCH`, `DAILY_FLEET`, `STOCK_TUNE`, reward in `dailyReward()` |
| Rider profiles | `PROF_NAME_MAX 24`, `PROF_BIO_MAX 200`, `COLOUR_OK` |
| Rivals | how many are queued up: `limit=8` on a board, `limit=12` in the daily |
| Badges | `BADGE_PINS 3`, the `BADGES` array (30 of them), tiers 1-3 |
| Weather | `WEATHERS` (grip, brake, wind, dark), `WEATHER_FROM_DAY` |
| Time trial | `TT_DIST 900`, `TT_SPLITS`, `TT_PENALTY 3000`, course seeded per week |

Seasons roll over from the clock — no scheduling, no server job. So does the
daily seed, off a **UTC** day number, which means it turns over at 20:00 in
South Florida. Move `DAILY_EPOCH` only if you also accept that every past day
number shifts.

**Never reorder `DAILY_FLEET` or `RTRACKS`.** The daily seed indexes into both.
Appending is safe between days; a reorder shipped mid-day puts two players on
different tracks while they both think they are riding today's.

**60 bikes.** Indexes 34–39 and 51–52 are code-unlocked secrets (`price 0`),
54–59 are season pass bikes, 50 is the 500k Apex Omega.

**Codes:** `julian dev soflolucas penguinong a1a bikelife nohands miami braaap
dev2 caleb eli`. Typing `adminabuse` opens the admin panel — but it is only a
door. Every admin action is authorised server-side against the `admins` table,
so a player who reads the passphrase out of the page source gets a panel where
every button is refused.

---

## Testing

There is no test framework. The pattern that works, used for every feature
here, is to **inject a harness inside the IIFE** in a throwaway copy:

```python
s = open('index.html').read()
marker = "requestAnimationFrame(loop);\n})();"
s = s.replace(marker, "requestAnimationFrame(loop);\n" + TEST_JS + "\n})();")
open('/tmp/test.html','w').write(s)
```

Then serve it, load it in the browser tool, and read results out of a `<pre>`
you append to the DOM. The browser tool's `javascript_tool` runs in an
**isolated world** — it cannot see page globals, but it *can* read the DOM.
That is why results go through an element.

Always `node --check` the extracted script after editing. It has caught real
typos and duplicate declarations that would have shipped.

**Write tests that fail for the right reason.** Several of mine passed or
failed spuriously: reading `S.spd` after a crash had already respawned the
bike, or asserting on a stub that a live fetch had replaced.

---

## Known open items

- **Split-screen halves are zoomed.** Inherent to cropping a 960-wide frame
  into a short, wide viewport. Proper fix is rendering each half at a wider
  internal width.
- **Leaderboard is cheatable.** Client-side game; a determined player can post
  any score through dev tools. Mitigated by a DB ceiling and a monotonic
  trigger, not solved. Only worth fixing if someone actually does it.
- **Crews have no invites.** Anyone can join any crew.
- **`1.5×` crew coins is effectively economy-wide** once everyone joins. Price
  future content accordingly.
- **Versus pays nothing** — no coins, XP or records, since two people share one
  account. Deliberate.
- **A daily attempt can be dodged by killing the tab.** Leaving through the
  menu banks the run, and a crash banks it, so the only way to get a second go
  is to close the tab mid-run — nothing was banked, so nothing was filed.
  `SAVE.daily.started` already records that the attempt was launched and is the
  hook if this ever needs closing; it is left open on purpose so a browser
  crash does not burn somebody's day.
- **The daily board needs `daily.sql` run.** Until it is, the mode plays and
  pays normally and the board tab says so in plain words rather than dying.
- **Profiles need `profiles.sql` run**, and it depends on `is_admin()` from
  `admin.sql`. Until it is, the profile screen says so and nothing else breaks.
- **The time trial board needs `trials.sql` run.** Until it is, the mode plays
  and your own best still saves; only the shared board is missing, and the
  board tab says so.
- **Badges added two columns to `profiles`**, so `profiles.sql` needs running
  again. It is idempotent and the `alter table ... add column if not exists`
  lines are safe on the live table. Until it is run, `profilePush()` notices
  the rejected column and re-files the card without the badge fields, so a
  card never goes stale waiting on the SQL - but nobody else can see your
  pinned three.
- **A bio is the only free text one player writes for another to read.** It is
  capped at 200 characters and escaped, and the admin panel has a *Moderate a
  profile* card that clears a name and bio, but there is no automatic
  filtering. That was the deciding argument against crew chat, so if bios turn
  into a problem the same reasoning applies: take the feature out rather than
  try to police it.

---

## Suggested next features

Already pitched and not built. Strongest first:

1. **A grace threshold on the daily.** A 0 m crash still burns the day. Below
   about 10 m, do not count the attempt and do not file a row.
2. **Crash flags on the daily track** — a flag where each friend died, with
   their name and distance on it. The `daily` table already holds every one of
   those numbers, so this is a fetch and a draw call: no table, no SQL.
3. **Ghost of the day** — the top daily run replays beside you. The track is
   already deterministic, so a run is just position samples; store a few KB on
   the winner's row at about 5Hz.
4. **Streak freeze** — one a week, bought with coins. Also softens the day a
   0m crash burns.
5. **More daily modifiers** — weather is the first one; the seed could just as
   easily pick a rule (no brakes, flips score double, one life at half speed).
6. **Rewind token** — one crash-undo per run. Kills frustration quits.
7. **Per-bike leaderboards** — makes all 60 bikes matter; reuses `scores`.
8. **Crew Wars** — weekly crew-vs-crew pairing.
9. **Wheelie School** — graded tutorial ladder; the game is hard to learn.

Deliberately rejected: **loot boxes / paid random pulls** and **coin wagering**
(gambling-adjacent, and the players are the owner's friends, some young), and
**crew chat** (moderation burden).

---

## Bugs worth remembering

Each of these shipped or nearly shipped, and each has a lesson.

- **Ramp mode rendered black for days.** A local `const held = heldTrick()` in
  `tickRamp` shadowed the module-level `held()` input helper added with
  rebindable keys — every ramp frame threw. *Lesson: grep for name collisions
  when adding a global helper.*
- **Announcements never appeared while riding.** `renderStreet()` runs in every
  non-ramp mode including the menu, so the 14-second timer burned behind the
  menu sheet and the id was written to `localStorage` as seen — permanently, on
  every device that ran the buggy build. *Lesson: fixing the cause does not
  undo poisoned persisted state; and reproduce the user's actual state before
  changing code. Three attempts were spent reasoning instead of reproducing.*
- **Style chain never reached the score.** Banking needed 3 straight seconds
  below 8°, and `styleAdd` reset that timer on every point added. A crash then
  wiped the chain, so a whole run scored nothing.
- **XSS in crew names.** Player-supplied names went into `innerHTML`. A crew
  called `<img onerror=...>` would have run code in every viewer's browser.
  Fixed with `esc()`. *Any text another player can type must be escaped.*
- **Admin passphrase ate a redeemed code.** The branch called
  `SAVE.codes.pop()` before the push that would have added it.
- **UTF-8 without a charset.** Em dashes rendered as mojibake for months.

---

## Working style that worked

- Verify against the live database with `curl` before pushing anything that
  depends on schema or policies.
- **Hold the push** when a feature needs SQL the owner hasn't run yet. A login
  wall or dead screen on a live site is worse than waiting.
- Screenshot the actual game after UI changes. Several overlap bugs were only
  visible that way.
- Commit messages here explain *why*, including what was measured. Keep that.
