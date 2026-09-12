# Cloud saves setup

The game plays fine without this — if `CLOUD.url` and `CLOUD.key` are left
blank it just uses local storage, exactly as before. Fill them in and accounts
switch on.

## 1. Create the project

1. Go to https://supabase.com and create an account and a new project.
2. Wait for it to finish provisioning (a minute or two).

## 2. Create the table

Open **SQL Editor**, paste the contents of `supabase-setup.sql`, and hit **Run**.

## 3. Turn off email confirmation

Usernames are mapped to internal addresses like `lucas@wheelie.local`, which
can't receive mail, so confirmation emails must be off or nobody can sign in.

**Authentication → Sign In / Providers → Email**:
- **Confirm email**: OFF
- Leave **Enable email provider** ON (it's what powers password login)

## 4. Paste your keys into the game

**Project Settings → API**, copy:
- **Project URL**
- **anon public** key

Then in `index.html` find the `CLOUD` block near the top of the script and fill
it in:

```js
const CLOUD = {
  url: "https://YOURPROJECT.supabase.co",
  key: "eyJhbGci...",          // the anon public key
  domain: "wheelie.local",
};
```

The anon key is *designed* to be public — it's in every Supabase web app.
Row level security is what protects player data, and step 2 set that up.

**Never paste the `service_role` key into the game.** That one bypasses row
level security entirely and would let anyone read and delete every save.

## 5. Deploy

```bash
git add -A && git commit -m "Enable cloud saves" && git push
```

## How saves merge

Players can play offline on two devices and produce two different saves.
Rather than letting the newer one overwrite the older, each field merges on
its own terms:

- **Best scores** take the higher number
- **Coins** take the higher balance (not the sum, so it can't be farmed by
  syncing back and forth)
- **Bikes, helmets, tricks, codes, finished quests** are unioned — anything
  earned anywhere is kept
- **Upgrade levels** take the higher level per bike; owned parts and engines
  are unioned
- **Paint, fitted engine, keybinds, active quests, current bike** follow
  whichever save was written more recently

## The other SQL files

`supabase-setup.sql` is the only one you have to run. Everything else adds a
system, and the game works without each of them — the feature simply does not
appear, and the screen that would have shown it says so. Run them in any order.

| File | What it adds |
| --- | --- |
| `leaderboard.sql` | The public score board |
| `score-caps.sql` | **Run this one.** Raises the score ceiling — see below |
| `daily.sql` | The daily seed run board |
| `trials.sql` | The weekly time trial board |
| `crews.sql` | Crews and the crew standings |
| `trusted-names.sql` | **Run this one.** Stops anyone putting somebody else's name on a score |
| `profiles.sql` | Rider profile cards |
| `world2.sql` | The Afterburn board |
| `admin.sql` | Admins, announcements and gifts |
| `admin-limits.sql` | Caps on what an ordinary admin may hand out |
| `events.sql` + `events-wild.sql` | Live events, all twenty kinds |
| `super-admin.sql` | Super admins: uncapped gifts, account deletion |
| `dynamic-admin.sql` | Global chat, polls and reactions |
| `password-reset.sql` | Self-service password reset |

### trusted-names.sql is not optional either

Only `profiles` ever checked that the username on a row belonged to the account
that wrote it. `scores`, `scores2`, `daily`, `trials` and `crew_members` all
took it straight off the request, and the row-level policies on them check the
`user_id` and stop there — so the name beside a score on the public board was
never verified. Worse, the admin panel resolves a gift target by that name, so
a row claiming to be somebody else could catch gifts meant for them.
`trusted-names.sql` stamps the name from the account on all five, and repairs
any row already filed under a name that was not true.

### score-caps.sql is not optional

The original `leaderboard.sql` capped each score at 100,000,000 with a CHECK
constraint. That is a number this game reaches, and because all three boards
live in one row, one score over the line got the whole write refused — so a
rider who crossed it silently stopped filing scores on *every* board, with no
error anywhere. `score-caps.sql` moves the columns to `bigint` and the ceiling
to nine quadrillion. Run it.

## If a player forgets their password

Run `password-reset.sql` and there are three ways back in, in the order you
should reach for them:

1. **They are still signed in somewhere.** Menu → **Change password**. Nothing
   is needed on the server for this; it goes through Supabase's own
   authenticated endpoint and works on every deployment.
2. **They added a recovery email at signup.** The sign-in screen has a
   **Reset** tab: username plus that email sets a new password on the spot.
3. **They did not.** A super admin can set one for them from the admin panel,
   or you can from **Authentication → Users** in the Supabase dashboard.

Read the top of `password-reset.sql` before you run it. Route 2 is weaker than
a mailed reset link and the file says exactly how: usernames map to
`someone@wheelie.local`, an address that cannot receive mail, so there is
nowhere to send a link — the recovery email is checked as a shared secret
instead. Anyone who knows a rider's username *and* the exact address they
signed up with can take that account. It is rate limited to five wrong answers
an hour, the failure message is the same whatever was wrong, and a successful
reset deletes every session the account had. If that trade is not one you want,
do not run the file: routes 1 and 3 keep working without it, and the Reset tab
tells players it is not set up.
