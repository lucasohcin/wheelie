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

## If a player forgets their password

There's no reset unless they added a recovery email at signup, because
username accounts have no verified address to send to. You can set a new
password for them from **Authentication → Users** in the Supabase dashboard.
