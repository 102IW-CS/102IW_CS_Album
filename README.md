# Photo Share

A private photo album for friends and colleagues. People create an account on the site, the owner approves them, and approved members can upload, view and download photos.

- **Page:** `index.html`, hosted on GitHub Pages at https://102iw-cs.github.io/102IW_CS_Album/
- **Accounts, database and photo storage:** Supabase (free plan)

## How it's put together

- The page is static, so it can't keep secrets. It only contains Supabase's **publishable** key, which is meant to be public.
- What protects the photos is the set of **access rules in the database** (`supabase/setup.sql`). They're enforced on Supabase's servers, so editing the page can't get around them:
  - New accounts start as **pending** and see nothing until an admin approves them.
  - Only approved members can see photos. Files are in a private bucket and open only through short-lived signed links.
  - People upload only into their own folder. They can delete their own photos; admins can delete any.
  - Who uploaded a photo, and when, is stamped by the server, so it can't be faked.
  - The first account ever created becomes the admin.
- Passwords are stored and checked by Supabase Auth; the page never sees or stores them.

## One-time setup

1. **Database:** Supabase → SQL Editor → New query → paste all of `supabase/setup.sql` → Run. It's safe to run again after changes.
2. **Site address:** Authentication → URL Configuration → set **Site URL** to `https://102iw-cs.github.io/102IW_CS_Album/` and add the same address under **Redirect URLs**. Email links (confirm, reset password) come back here.
3. **Email confirmation (recommended: off):** Authentication → Sign In / Providers → Email → turn off **Confirm email**. You approve every account anyway, and Supabase's built-in email sender only allows a few emails per hour. Password-reset emails still work.
4. **Become the admin:** open the site and create your account **first**.

## Albums

- Any approved member can start an album and add photos to it. Photos added outside an album land in **Unsorted**.
- **Move to…** (select photos, or from the photo viewer) files photos into an album or creates a new one on the spot.
- The album's creator or an admin can rename it, set its cover (**Set as cover** in the viewer) or delete it. Deleting an album never deletes photos; they go back to Unsorted.
- People can move or delete only photos they added; admins can do it for any photo.
- Each album has its own link (`…/#a-<id>`), so you can send someone straight to it.

## Everyday use

- **Owner contact:** Members → **Album settings** sets the name, phone and email shown to people waiting for approval. They're stored in the database (visible only to signed-in people), not in this public repo.
- **Password rules:** the sign-up form requires 8+ characters with upper and lower case, a number and a symbol. To enforce the same rules on the server too: Authentication → Sign In / Providers → Email → set minimum length 8 and require lowercase, uppercase, digits and symbols.
- **Approving people:** tap **Members** (a red number shows how many are waiting) → **Approve** or **Decline**. **Turn off** removes someone's access later; **Restore** gives it back.
- **Storage:** the free plan has 1 GB of files and 5 GB of downloads a month. With "Optimize" on, a phone photo is about 0.5–1.5 MB.
- **Paused project:** Supabase pauses free projects after a week with no activity. If the site says it can't reach the album server, open the Supabase dashboard and resume the project.

## Features

Albums with covers · justified gallery layout · Drag and drop, file picker or paste to upload · automatic resize and GPS removal · thumbnails · live updates when others add photos · search and sort · full-screen viewer with swipe · download one or a ZIP of many · password reset · works on phones.
