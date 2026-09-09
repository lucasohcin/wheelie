# SoFlo Wheelie Life — handoff

Everything a fresh session needs to pick this up. Written 3 Sep 2026, updated 9 Sep 2026 (worlds, admin limits, events).

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
- **Anything a rebirth clears needs a line in `mergeSaves`.** The merge exists
  to never lose progress, so its instinct — keep the bigger number, union
  anything owned — hands a wiped garage straight back off the other device.
  See the rebirth section below.
- Bike indexes are positional. **Append new bikes; never reorder `BIKES`.**
- `PRICES` is index-aligned with `BIKES`. Pad it when you append.
- **`SAVE` describes the world you are standing in.** `coins`, `bikes`, `bike`,
  `best`, `bestRide`, `rampBest`, `spot` and `track` mean different things in
  Afterburn; the other world's copies live in `SAVE.alt`. Anything new that is
  per-world must go in `WORLD_FIELDS` *and* be handled in `mergeWorld`.
- **`W1_SPOTS` and `W1_TRACKS` are frozen.** The daily and the trial draw
  their track with `W1_TRACKS`, never `RTRACKS.length`. Changing either number
  moves the track under every day and week already ridden.

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
| Two-player | `vsOpenSetup()` → `startVersus()` / `vsTick()` / `vsRender()` / `renderVersus()` |
| Rebirth | `canRebirth()` / `doRebirth()`, cost card in `rebirthCost()`, screen in `renderRebirth()` |
| Worlds | `setWorld()` swaps `WORLD_FIELDS` with `SAVE.alt`; `worldSplit()` / `mergeWorld()` for the merge |
| Backdrop props | `prop()` dispatches on `sp.prop`; billboards from `BOARDS` / `BOARDS_W2` via `sp.boards` |
| Live events | `EVENTS` catalogue, `pullEvents()` on the announcement beat, `evtMul(kind)` at the multipliers |
| Admin limits | all of it in `admin.sql`: `grants_guard()` trigger and `grant_budget()` |
| Mini bodywork | `drawMini()`, silhouettes in `MINI_TANK` |
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

**Rebirth** is the only thing in the game that takes progress away. At rider
level 25 you may hand back your coins, your level, your season pass and every
bike, upgrade, helmet and trick a coin ever paid for, in exchange for a
permanent **1.5x on every coin you earn**, and a bike that is not for sale at
any price. They stack and never stop stacking: the fourth rebirth rides at
5.06x, the eighth at 25.6x.

The gate is a **flat** level 25 every time rather than a rising one, and that
is the whole design. Coins multiply and XP does not, so a rising gate would
get slower every pass and the loop would die on its own; a flat gate gets
*faster* every pass, because you climb it on better bikes bought sooner. That
is the difference between a prestige loop worth riding and a punishment.

What survives is everything a coin never bought: every record, badges, quest
progress, redeemed codes and the bikes they unlocked, your crew, your profile,
and the rebirth bikes themselves. What goes is everything a coin did buy.
Records survive for a second reason as well as fairness - `scores` has a
monotonic trigger and `trials` a `least()` one, so a wiped best would come
straight back on the next sync and only the local number would ever have
moved. Wiping them is not something this client *can* do.

Three things here are easy to get wrong.

**`mergeSaves` would have undone it.** Every rule in that function is built to
never lose progress: bests take the higher number, anything owned is unioned.
Point that at a rebirth and the other device hands the whole garage straight
back the next time it syncs. A save that has been through more rebirths is by
definition the later one, so it now wins outright on coins, XP, bikes, lids,
tricks, tune, paints and the season - and only on those. Records, badges and
quest progress are not in that list, because a rebirth never touched them, so
a best set on the old device still counts. The tests cover both argument
orders, because a merge that is not symmetric is a merge that depends on which
device woke up first.

**Kept bikes are read out of `CODES`, not listed.** `keptBikes()` walks the
codes you have actually redeemed and protects whatever bike each one granted,
so a code added later is safe without anybody remembering to come back here.
The rebirth bikes protect themselves the same way, off `REBIRTH_BIKES`.

**`earn()` used to bank coins one at a time** in a `while` loop. At 25x that
loop runs thousands of times a tick, so it now takes the whole part in one go
and carries the fraction. The ramp's coin pickups were adding 5 straight to
the wallet, bypassing `coinMult()` entirely - which meant they had never paid
the crew bonus either - so they go through `earn()` now.

Where the multiplier applies is deliberately the same line the crew bonus
already drew: **coins earned while riding**. Fixed payouts - the daily reward,
the trial completion bonus, quest rewards, season tiers, admin grants - are
grants, not earnings, and are untouched. Worth revisiting if the daily starts
feeling stingy to somebody eight rebirths deep.

Past the eighth rebirth there are no bikes left, so it pays `REBIRTH_PAYOUT`
coins instead and the multiplier keeps stacking. Nobody is likely to get
there; it exists so the button never has nothing to give.

**Admin limits and live events** exist because the game was being given away.
Handing one player a pile of coins is invisible to everybody else and makes
the game worse for them, so the boring power is now capped and the interesting
one was built.

Every cap is in `admin.sql`, not in the panel, and that is the whole point.
The passphrase is a door; anyone who reads the page source can POST to the
REST endpoint directly, so a limit written in JavaScript is decoration. The
`grants_guard()` trigger enforces, against `auth.uid()`: no gifting yourself,
100,000 coins per recipient per day, 250,000 a day per admin across everyone,
5,000 XP a gift and 20,000 a day, 20 gifts a day, and nothing with a bike
index of 88 or above because that is Afterburn. The panel calls
`grant_budget()` to show the running total before an admin types a number
rather than after the database refuses it. PostgREST passes a `raise exception`
message straight through as `data.message`, which `api()` already surfaces, so
the trigger's own words are what the admin reads.

**Grants had a world bug worth remembering.** Everything an admin can send is
a South Florida thing, but `SAVE` means whichever world you are standing in -
so a 100,000 coin gift arriving while the player was in Afterburn landed as
100,000 *embers*, and a world 1 bike went into the Afterburn garage where
`normaliseSave` threw it straight back out. `pullGrants()` now writes into
world 0 explicitly, wherever the player happens to be.

**Announcements are signed.** They used to arrive as "ANNOUNCEMENT", which
made admin abuse anonymous. `broadcasts` gained `author`, stamped by a trigger
off the account rather than taken from the request, for exactly the reason a
profile username is.

**Events** are five kinds - Coin Rush, Double Time, Raining Coins, Moon
Gravity, Turbo Hour - polled on the same 45 second beat as the announcements
and applied straight into multipliers that already existed. Nothing is stored
per player and nothing needs claiming. One live per kind, enforced by a
trigger rather than a partial unique index, because `now()` is not immutable
and Postgres will not accept it in an index predicate. Two of a kind would
have meant the client inventing a meaning for stacked multipliers; `evtMul`
takes the higher of a kind and never the product, for the same reason.

None of it reaches Afterburn. `evtMul` returns 1 there and every ride effect
checks the same thing, because a 100x coin hour would flatten a currency whose
whole point is that it is slow.

Two things to know. Turbo is baked into `CUR` by `buildBike`, so `pullEvents`
calls `refreshBike()` when the live set changes or an event that starts
mid-session does nothing. And **Raining Coins pays flat, straight to the
wallet, not through `earn()`** - a drop is a fixed event payout like the daily
reward, not coins earned by riding. Putting it through `earn()` meant Coin
Rush multiplied it too: measured at 419,000 coins in thirty seconds with 100x
plus rain, against 19,000 once it was flat. Two events that each make sense
should not compound into a third that does not.

**Afterburn** is the second world, and five rebirths is the door. It has its
own currency (embers), its own forty bikes, its own five street maps and three
ramp tracks, and its own leaderboard. You cannot spend coins there, the season
pass does not exist there, and none of your South Florida bikes came with you.
Street, Ride Out, Ramp and versus are the modes; the daily, the trial, quests,
crews, legend bikes and codes are all South Florida systems and are simply not
shown. Switching is free and costs nothing either way - a one-way door would
mean a mis-click at the entrance costs somebody their entire garage.

It is built as a **swap, not a second set of fields**. `SAVE.coins`,
`SAVE.bikes`, `SAVE.best` and five more always describe the world you are
standing in; the other world's copies sit in `SAVE.alt` and the two trade
places in `setWorld()`. That is why the shop, the garage, the HUD, the physics
and every record write needed no changes at all - they were already reading
"the current wallet" and "the current garage". The same trick versus already
used on the module globals, one level up.

The price of it is `mergeSaves`. Two devices can easily be standing in
different worlds, and merging `coins` against `coins` would pour embers into a
coin wallet and lose one of them. Both saves are now pulled apart by
`worldSplit()` into world 0 and world 1, each side merged against its opposite
number by `mergeWorld()`, and the result reassembled facing whichever way the
newer save faced. The rebirth override applies to world 0 only.

Four things there are easy to get wrong.

**The daily and the trial drew their track with `RTRACKS.length`.** Appending
three Afterburn tracks would have moved the track under every day and week
already ridden, and dropped South Florida dailies onto maps most riders cannot
reach. Both now draw with the frozen `W1_TRACKS`. The test suite pins day 243,
248 and 270 and weeks 2900 and 2960 to exact tuples computed before the change,
and asserts that no day or week in the first 900 of either ever lands on an
Afterburn track.

**A garage must never hold the other world's bikes.** `normaliseSave` filters
`SAVE.bikes` by `w2` against the active world and `mergeWorld` does the same,
so a bad merge, an old save or a hand-edited `localStorage` cannot put a bike
somewhere it cannot be priced, ridden or sold.

**Rebirth is a South Florida loop and must not reach across.** `canRebirth()`
is false in Afterburn, `keptBikes()` never sees world 2, and `doRebirth()`
clears only the tune entries whose bike index is below `W2_BIKE0` - the two
worlds' indexes never overlap, which is what makes that safe.

**Embers are flat.** Everybody standing in Afterburn has at least five
rebirths, so letting the rebirth stack or the crew bonus through would hand
them a 7.6x head start on a currency whose entire point is that it is slow.
`coinMult()` returns `W2_RATE` there and nothing else.

The maps are not recolours. Each Afterburn spot names its own roadside `prop`
- bridge pylons, container cranes, sawgrass, marker posts, neon signs - and
its own billboard set, because a recoloured sky is not a different place if
the same A1A hoarding goes past every four seconds. `palmT` / `palmL` /
`palmL2` are read only by `palm()` and `prop()`, so on a world 2 spot they
simply mean "the prop's three colours".

**Versus** swaps the module globals (`S`, `POSE`, `CUR`, `ctx`, `target`,
`SCALE/DPR/OFFX/OFFY`, and now `W`/`BIKE_X`) around each rider, renders each to
its own offscreen canvas, and blits them into stacked halves. `S` is `let`, not
`const`, for exactly this reason. Always restore globals in a `finally`.
It was unreachable until 5 Sep: `#mVersus` had no click handler and
`startVersus()` was never called from anywhere. It now opens a setup sheet
where each rider picks from the bikes you own and you set the round length.

A round is a **fixed length of time**, not a race to a number, so both riders
always finish together and a bad first minute is not fatal. `VS.phase` walks
`setup → count → run → over`; the clock is stepped by `vsClock()` inside the
physics loop rather than off the renderer, so a round is the same length on
every machine. A crash costs the chain you were holding, exactly as on the
street, but `VS.stat[i].total` carries the banked score across crashes and the
live number is `total + S.score` - without that one crash would zero a whole
round and there would be no reason to keep riding.

Versus still pays nothing, and that is now actually true. It was leaking:
`crash()` called `awardXP()` and `persist()`, and two record writes inside
`tickStreet` were unguarded, so a versus round moved your level and your
street best. The crash path routes through `vsCrash()` instead, and both
writes check `VS.on`. Neither rider's bike touches `SAVE.bike` either - both
get their own build in `VS.cur`, so the garage is exactly as you left it.

The halves are no longer zoomed. The old code rendered at the window's own
width and cropped a short slice, which upscaled roughly 2x. `vsWidth()` picks
the world width the half's shape actually asks for (about double), so all 540
of world height fits with nothing cropped and nothing stretched. That costs
about twice the pixels; `tuneQuality` still applies, because the chosen width
falls out of `cv.width`, which `DPR` drives.

The full riding HUD is suppressed in versus - two of them in a half-height
viewport is unreadable - so `vsHUD()` draws a compact board per half, plus the
crash card that would otherwise be lost with `drawHUD`.

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
| `profiles` | public | own row only, plus `is_admin()` for taking a bio down. `badges` / `badge_count`, then `rebirths`, were added later; re-run `profiles.sql` for them |
| `trials` | public | own row only, and a trigger that only ever lets a time come down |
| `scores2` | public | own row only, scores monotonic (trigger). The Afterburn board; `world2.sql` |
| `events` | public | admins insert/delete, author stamped by trigger, one live per kind; `events.sql` |

SQL lives in `supabase-setup.sql`, `leaderboard.sql`, `crews.sql`, `admin.sql`,
`daily.sql`, `profiles.sql`, `trials.sql`, `world2.sql`, `events.sql`.
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
| Versus | `VS_LENGTHS` (60/90/150s), `VS_KEYS`, `VS_TINT`, `vsWidth()` clamp |
| Rebirth | `REBIRTH_LEVEL 25`, `REBIRTH_MULT 1.5`, `REBIRTH_BIKES` (80–87), `REBIRTH_PAYOUT 250000` |
| Worlds | `W2_REBIRTHS 5`, `W2_RATE 0.012`, `W2_BIKE0 88`, `W1_SPOTS 4`, `W1_TRACKS 2`, `W2_SPOTS 5`, `W2_TRACKS 3` |
| Live events | `EVENTS` (five kinds), `RAIN_PAY 250`, turbo `1.22`, moon gravity `0.42` |
| Admin gift caps | `COIN_ONE 100000`, `COIN_DAY 250000`, `XP_ONE 5000`, `XP_DAY 20000`, `ROWS_DAY 20` — **all in `admin.sql`** |

Seasons roll over from the clock — no scheduling, no server job. So does the
daily seed, off a **UTC** day number, which means it turns over at 20:00 in
South Florida. Move `DAILY_EPOCH` only if you also accept that every past day
number shifts.

**Never reorder `DAILY_FLEET` or `RTRACKS`.** The daily seed indexes into both.
Appending is safe between days; a reorder shipped mid-day puts two players on
different tracks while they both think they are riding today's.

**128 bikes.** Indexes 34–39 and 51–52 are code-unlocked secrets (`price 0`),
54–59 are season pass bikes, 50 is the 500k Apex Omega. 60–79 were added on
5 Sep: eight minis, six motocross (one of them a supermoto), four road bikes,
an e-moto and a drag bike, all bought with coins. **80–87 are the rebirth
bikes**, added 9 Sep: `secret` and `price 0`, so the garage never lists them
to somebody who has not earned one, and they are the only bikes in the game
with no purchase path at all. **88–127 are the Afterburn garage**, forty bikes
that exist only in the second world and are bought only with embers; they are
`w2:true` and `secret:true`, and `PRICES` holds their ember price, which works
because `SAVE.coins` *is* embers while you are over there.

**`cls:"mini"` is a fifth body class**, drawn by `drawMini()`. A mini is not a
big bike drawn small - the wheels are tiny beside the rider, the frame is one
backbone rather than a cradle, the motor hangs under the seat - and putting
them through `drawNaked` with a short wheelbase read as toy motorcycles. Five
variants (`shape.mini`: `grom` `monkey` `pit` `trail` `pocket`) branch on
structure, because a rigid-forked trail mini and a faired pocket racer share
almost nothing. `MINI_TANK` stores silhouettes as **a fraction of the
wheelbase across and a multiple of the seat height up**, so one shape fits a
104 trail mini and a 130 pit bike; absolute coordinates put the tank through
the frame on half of them. The minis also fill the gap under the 2,600-coin
Grom that the early game did not have - the Coleman is 1,200.

**Codes:** `julian dev soflolucas penguinong a1a bikelife nohands miami braaap
dev2 caleb eli afterburn`. `afterburn` opens the second world without the five
rebirths - it grants the door only, not the multiplier and not a wiped garage,
which is how Afterburn gets tested and shown before anybody has ground five
rebirths out. Typing `adminabuse` opens the admin panel — but it is only a
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

**Give the suite a known starting save.** It reads `SAVE` after load, so it
inherited whatever the last harness left in `localStorage` on that origin: a
leftover `world:1` sent every rebirth test through `canRebirth()`'s `!inW2()`
guard and the whole run died on a null. It passed on the next reload. A suite
whose result depends on which page you opened last is worth nothing - clear
the key and set the world explicitly first.

**`requestAnimationFrame` does not fire while the browser pane is hidden**, so
a harness that starts a run and waits will measure a bike that never moved.
Call `tickStreet()` / `tickRamp()` in a loop instead: it drives the real
physics and does not depend on the pane being painted.

**Compare runs only when the trajectories are identical.** Measuring the coin
multiplier across three live runs gave 3.525 against an expected 3.375, purely
because the runs crashed in different places. Stopping at the first crash made
them identical, and reading `SAVE.coins + S.coinAcc` rather than `SAVE.coins`
removed the integer truncation, which at 5 coins was a fifth of the answer.
Both then matched to nine decimal places.

**Write tests that fail for the right reason.** Several of mine passed or
failed spuriously: reading `S.spd` after a crash had already respawned the
bike, or asserting on a stub that a live fetch had replaced.

---

## Known open items

- **Leaderboard is cheatable.** Client-side game; a determined player can post
  any score through dev tools. Mitigated by a DB ceiling and a monotonic
  trigger, not solved. Only worth fixing if someone actually does it.
- **Crews have no invites.** Anyone can join any crew.
- **`1.5×` crew coins is effectively economy-wide** once everyone joins. Price
  future content accordingly.
- **Versus pays nothing** — no coins, XP or records, since two people share one
  account. Deliberate, and verified: a street run moves `best`/`xp`/`coins`, a
  full versus round after it moves none of them.
- **Versus is keyboard only.** The touch pad drives P1, which is not a second
  player. Fine on a sofa with a laptop; no use on a phone.
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
- **Events need `events.sql` run**, and the gift caps need **`admin.sql`
  re-run**. Until `events.sql` is run no event can start, the menu card and
  the riding banner never appear, and the admin card says so. Until `admin.sql`
  is re-run **there are no caps at all** - the panel still shows the limits as
  text, but nothing enforces them.
- **The Afterburn board needs `world2.sql` run.** Until it is, the second
  world plays and pays normally and your own records still save; only the
  shared board is missing, and the board tab says so. `scoresPush()` swallows
  the rejection so nothing else breaks.
- **A rider profile still shows South Florida numbers.** The card reads
  `scores`, not `scores2`, so somebody deep in Afterburn shows their old
  street bests next to an Afterburn bike as their avatar. Harmless, and worth
  fixing when profiles next get touched.
- **Rebirth added a `rebirths` column to `profiles`**, so `profiles.sql` needs
  running again. Until it is, `profilePush()` notices the rejected column and
  re-files the card without it, so nothing goes stale - only the REBIRTH chip
  is missing from other people's view of your card. Your own count is in your
  save and is never at risk.
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
- **Versus shipped with no way in.** The button, the CSS, the split-screen
  renderer and the input mapping were all written and correct; nobody had
  added the one `addEventListener` line, so `startVersus()` was dead code for
  weeks and nobody noticed because the button looked like the others.
  *Lesson: a feature is not done until you have clicked it in the built page.*
- **`[hidden]` loses to a class that sets `display`.** `.passbanner` and
  `.rbbanner` set `display:flex`, which outranks the browser's own
  `[hidden]{display:none}`, so `el.hidden = true` did nothing and both kept
  showing in Afterburn. The empty broadcast pill that had been sitting under
  the level bar on every menu for months was the same bug. One global
  `[hidden]{display:none !important}` fixed all of it. *`.sheet[hidden]` was
  already working around this further up the stylesheet - the workaround was
  there, the lesson had not been written down.*
- **The second call site is the one that bites.** Routing the roadside props
  through `prop()` was done in `drawScene` and missed the copy in the ramp
  renderer, so treeless Afterburn ramp tracks still lined the horizon with
  South Florida palms. *Grep for the function you are replacing, do not fix
  the one you happened to be reading.*
- **Absolute coordinates do not scale.** The first mini bodywork used the MX
  tables' fixed y values, so a 104mm trail mini wore a tank halfway through
  its own frame. Normalising to wheelbase and seat height fixed all five
  variants at once. *Screenshot the bike, do not reason about the polygon.*

---

## Working style that worked

- Verify against the live database with `curl` before pushing anything that
  depends on schema or policies.
- **Hold the push** when a feature needs SQL the owner hasn't run yet. A login
  wall or dead screen on a live site is worse than waiting.
- Screenshot the actual game after UI changes. Several overlap bugs were only
  visible that way.
- Commit messages here explain *why*, including what was measured. Keep that.
