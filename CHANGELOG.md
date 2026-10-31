# Change log: Photo Share (102IW)

Every change to this site, newest first, in plain words. Database changes are in `supabase/migrations` (file names start with the date), and `supabase/setup.sql` holds all of them for a fresh setup.

The personal copy of this site (https://b4anjan.github.io/PhotoShare/) has its own change log. Since Oct 30, 2026 the two have the same features, except that the personal site also has **Share outside**.

## 2026-10-30 (evening): same features as the personal site

**Private messages (new)**
- A **Messages** button: any approved member can chat one-to-one with any other approved member. Text only.
- Private: only the two people can read a conversation. The database refuses everyone else, admins included.
- Admins (Members → Settings → Private messages) see totals only, choose how long messages are kept (30 days to 1 year, or never deleted), and can delete old messages to free space.
- Finding people: search by name or email as you type, best matches first, A–Z when empty. Members only ever see a shortened email such as b•••@gmail.com.
- Taking a message back: **Undo** for 5 seconds after Send, **Unsend** your own message for both people within 24 hours (the text is erased), **Delete for me**, and **Copy**.
- Live: new messages and the unread count arrive without refreshing.

**Sign-in page**
- Sign-in pictures managed by admins (Members → Settings → Sign-in pictures): up to 40 pictures with caption and credit, kept in their own public storage area, apart from members' photos. Resized to 1200 px with location data removed.
- The pictures rotate: 3 at random on each visit, then one card changes at the speed the admin picks (3 seconds to 1 minute, or not at all; 8 seconds by default). They hold still while the mouse is over them.
- Until at least 3 pictures are added, drawn scenes fill the cards (8 scenes now, up from 3).
- The sign-in and create-account box glows amber on hover and while someone is typing in it.

**Terms and privacy**
- Terms of Service and Privacy Policy now cover private messages, unsending, the shortened emails in search, and the public sign-in pictures.

**Not included on purpose**
- Share outside (public links and posting to Instagram, Facebook, X and other apps) is on the personal site only. 102IW photos stay members-only.

## 2026-10-30

**Sign-in and accounts**
- Optional automatic approval: admins can let new people in as soon as they confirm their email, optionally only for chosen email domains (Members → Settings → New accounts). Switching back to manual approval works at any time.
- Real email addresses only: new accounts confirm their email first, throwaway-email services are refused, and only confirmed accounts can be approved.
- Account emails (confirm, reset password) now come from photo.share.102cs@gmail.com instead of Supabase's default sender.
- Reset-password screen: clearer wording. The reset link itself signs you in, so the skip button now reads "Keep my old password".
- Sign-in session rules set by the admin: sign out after 5 minutes to 4 hours of no activity (with a "Still there?" warning a minute before), and choose whether people must sign in again after closing the browser.

**Terms, privacy and your account**
- Terms of Service and Privacy Policy pages, modeled on Supabase's layout, each opening in its own page. Creating an account needs an "I agree" tick.
- My account page: change your name or password, download all your photos as a ZIP, see when you accepted the Terms, and delete your account.
- Members shows who hasn't accepted the Terms yet, and when each person accepted.

**Members (admins and moderators)**
- Built for hundreds of members: search by name or email, filters (Waiting, Active, Moderators, Admins, Turned off), sorting and paging.
- Admins can remove a member.
- Clearer message when a filter shows nobody.
- Settings tab: fields no longer stretch apart, and the box closes after Save settings.

**Inbox (admins)**
- Built for hundreds of messages: search, Unread/Read and topic filters, sorting, paging.
- Admins choose how long read messages are kept before they're deleted automatically.

**Contact page and site**
- Contact page for questions, with messages arriving in the admin Inbox.
- Fonts and libraries are stored with the site instead of loaded from other websites.
- Phone header keeps "Photo Share" on one line; "Sign out" shows as a word whenever it fits.

**Fixes**
- Creating an album works again (the visibility rule now reads the new album's own fields).

## 2026-10-29 — First version

- Photo Share site on GitHub Pages, with Supabase for accounts, the database and photo storage.
- Accounts: sign up, then an admin approves you. Strong-password rules.
- Albums: private by default. Albums can be shared with everyone, with chosen members, or by invite link. Album delete.
- Photos: upload with optional resizing, move between albums, delete.
- Roles: admins and moderators. Removal requests for photos someone wants taken down.
- Owner contact card for people waiting for approval.
- Gallery redesign, light and dark themes (dark by default).
- Footer with copyright and design credit; site icon and browser theme color.
- Database hardening: helper functions in a private schema, narrower access, catch-up for early sign-ups.
