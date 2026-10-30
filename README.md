# Photo Share

A private photo album for friends and colleagues. People create an account on the site, the owner approves them, and approved members can upload, view and download photos.

- **Page:** `index.html`, hosted on GitHub Pages at https://102iw-cs.github.io/102IW_CS_Album/
- **Accounts, database and photo storage:** Supabase (free plan)
- **Terms of Service and Privacy Policy:** `terms.html` and `privacy.html` (shared `legal.css` / `legal.js`). New accounts must tick “I agree”; the accepted version and time are saved with the account. Members who signed up earlier are asked once. To publish a revised version, update both pages' version line and `TERMS_VERSION` in `index.html`, and everyone is asked to accept again.
- **Contact page:** `contact.html` — design & development inquiries, plus a plain-language explanation of how the site works and keeps photos private

## How it's put together

- The page is static, so it can't keep secrets. It only contains Supabase's **publishable** key, which is meant to be public.
- What protects the photos is the set of **access rules in the database** (`supabase/setup.sql`). They're enforced on Supabase's servers, so editing the page can't get around them:
  - New accounts start as **pending** and see nothing until an admin approves them.
  - **Members see only their own photos and albums, plus whatever is shared with them.** Admins see everything.
  - Files are in a private bucket and open only through short-lived signed links, checked against the same rules.
  - People upload only into their own folder. Only the uploader or an admin can move or delete a photo.
  - Who uploaded a photo, and when, is stamped by the server, so it can't be faked.
  - The first account ever created becomes the admin.
- Passwords are stored and checked by Supabase Auth; the page never sees or stores them.
- Fonts and code libraries are served from `vendor/` on this site, so the only outside service a visitor's browser talks to is Supabase.

## One-time setup

1. **Database:** Supabase → SQL Editor → New query → paste all of `supabase/setup.sql` → Run. It's safe to run again after changes. (`supabase/migrations/` holds upgrade scripts that avoid drop statements, for applying changes without a confirmation prompt.)
2. **Site address:** Authentication → URL Configuration → set **Site URL** to `https://102iw-cs.github.io/102IW_CS_Album/` and add the same address under **Redirect URLs**. Email links (confirm, reset password) come back here.
3. **Email confirmation (recommended: off):** Authentication → Sign In / Providers → Email → turn off **Confirm email**. You approve every account anyway, and Supabase's built-in email sender only allows a few emails per hour. Password-reset emails still work.
4. **Become the admin:** open the site and create your account **first**.

## Albums and sharing

- Members create albums and add photos. Everything starts **private** (only the owner and admins see it). Photos added outside an album land in **Unsorted**.
- **Share** (on an album, or on a single photo in the viewer) — whoever created it, or an admin:
  - **Everyone:** every approved member can see it.
  - **Specific members:** pick people by name.
  - **Invite link:** for non-members. Opening it leads to sign in / create account; after admin approval the item appears for them. Links last 30 days and can be turned off.
- People who can see an album can add their own photos to it. Single photos shared with you appear under **Shared with you**.
- **Deleting:** only the person who added a photo (or created an album), or an admin. Others use **Request removal**; owners see a **Requests** badge and choose **Delete it** or **Keep it**. Deleting an album can keep its photos (they go to Unsorted) or delete your own photos in it.
- Each album has its own link (`…/#a-<id>`).

## Roles

- **Admin:** sees everything, manages all albums, members and roles. The first account is the admin.
- **Moderator:** approves, declines and turns off member accounts; doesn't see others' private photos; can't change roles or act on admins/moderators.
- Change roles in **Members**. Nobody can change their own role, so there's always an admin.

## Everyday use

- **Owner contact:** Members → **Settings** sets the name, phone and email shown to people waiting for approval. They're stored in the database (visible only to signed-in people), not in this public repo.
- **My account** (your name or the person icon in the header): change your name (updates it on all your photos and albums), change your password (asks for the current one first), download all your photos as a ZIP, see when you accepted the Terms, and delete your account (optionally with your photos and albums; type DELETE to confirm; the last admin can't delete themselves).
- **Terms status:** Members shows a *Terms not accepted* filter, and each person's details say when they accepted.
- **Sign-in sessions:** Members → **Settings** → *Sign out after no activity* (5 min to 4 hours, or never; a “Still there?” warning comes a minute before) and *When the browser is closed* (sign in again, or let people tick “Keep me signed in”). The site enforces these in each browser; Supabase’s server-side session limits need a paid plan. Signing out only signs out that device.
- **Password rules:** the sign-up form requires 8+ characters with upper and lower case, a number and a symbol. To enforce the same rules on the server too: Authentication → Sign In / Providers → Email → set minimum length 8 and require lowercase, uppercase, digits and symbols.
- **Inbox:** messages sent from the contact page show under **Inbox** (admins only). Search by name, email, phone or message text; filter by Unread/Read and topic; sort newest or oldest. Messages load 30 at a time from the server, so hundreds stay quick. Opening a message marks it read; Reply by email quotes the original. Tick several to mark read/unread or delete together, **Mark all read** clears the badge, and **Download CSV** saves everything that matches the current search for Excel. The sliders button in the Inbox sets **auto-delete**: read messages are removed 30/60/90 days, 6 months or 1 year after they arrive (unread ones never are). The database does the cleanup whenever a message arrives or an admin opens the Inbox. Anyone can send; only admins can read. The server rejects malformed messages and limits floods (3 per email per day, 30 per hour overall).
- **Approving people:** tap **Members** (a red number shows how many are waiting) → **Approve** or **Decline** right on the row, or pick the **Waiting** filter and **Approve all**. Search by name or email, filter by Waiting / Active / Moderators / Admins / Turned off, and tap a person to see their details, role and access controls. **Turn off** removes someone's access later; **Restore** gives it back. Admins also see **Remove**, which deletes the account for good (optionally with their photos and albums).
- **Storage:** the free plan has 1 GB of files and 5 GB of downloads a month. With "Optimize" on, a phone photo is about 0.5–1.5 MB.
- **Paused project:** Supabase pauses free projects after a week with no activity. If the site says it can't reach the album server, open the Supabase dashboard and resume the project.

## Features

Private albums with sharing to everyone, named members or invite links · removal requests · moderator and admin roles · light/dark theme (dark by default) · justified gallery layout · Drag and drop, file picker or paste to upload · automatic resize and GPS removal · thumbnails · live updates when others add photos · search and sort · full-screen viewer with swipe · download one or a ZIP of many · password reset · works on phones.

---

© 2026 Mohan Karki. All rights reserved. Designed and developed by Mohan Karki.
