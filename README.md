# Photo Share — setup

A single `index.html` that lets invited people upload, view and download photos. GitHub Pages hosts the page; a **private** GitHub repo stores the photos. There's no server: the page talks straight to the GitHub API with each person's own token.

## Why it's set up this way

- **GitHub Pages is static.** It can serve the page but can't accept uploads, so the page writes to a repo through the GitHub API instead.
- **The page and the photos are separate repos.** The page has no secrets, so it can be public. The photos repo stays private, so only people with a token can see them.
- **Each person uses their own token.** Never put a token in the HTML. Anyone could read it, and GitHub automatically revokes tokens it finds in public repos.
- **Use an organization, not your personal account.** Fine-grained tokens can't reach another user's personal repo when you're only a collaborator. They *can* reach a repo owned by an organization you belong to, scoped to that one repo.

## One-time setup (you)

1. **Create a free organization** on GitHub: profile menu → *Your organizations* → *New organization* → Free. Example name: `karki-photos`.
2. **Create the photo repo** in that org: `photo-share`, **Private**. Leaving it empty is fine, since the page creates the first commit.
3. **Invite people:** Org → *People* → *Invite member*. Then in the repo, go to *Settings → Collaborators and teams* and give them **Write** (or **Read** for view-only).
4. **Allow fine-grained tokens:** Org → *Settings → Personal access tokens*. Allow fine-grained tokens. Either turn off "require approval" or approve each request under *Pending requests*. A pending token can't read the private repo yet.
5. **Host the page:** create a **public** repo in the same org, for example `album`. Add `index.html`, then go to *Settings → Pages → Deploy from branch → main / root*. The site will be at `https://karki-photos.github.io/album/`.
6. **Point the page at the photo repo:** edit `CONFIG` at the top of the script:
   ```js
   owner: 'karki-photos',
   repo:  'photo-share',
   ```

> Hosting the page under the organization's `*.github.io` keeps saved tokens separate from pages on your personal `github.io` site. Every project site under one account shares a single browser origin.

## Each friend (once)

1. Accept the org invite.
2. GitHub → *Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token*
   - **Resource owner:** the org (`karki-photos`)
   - **Repository access:** Only select repositories → `photo-share`
   - **Permissions → Contents:** Read and write (Read-only for viewers)
   - **Expiration:** 90 days is a sensible default
3. Open the site and paste the token. Tick "Remember on this device" only on their own phone or PC.

## What it does

- Drag and drop anywhere, use the file picker, or paste with Ctrl+V. Multiple files are supported, and non-images are skipped.
- **Optimize** (on by default) resizes to 2560 px and re-saves as JPEG. This keeps the repo small and **removes GPS location data**. GIFs are left unchanged.
- Generates a small thumbnail for each photo so the gallery loads fast. Thumbnails are cached on the device.
- Saves up to 10 photos per commit. If two people save at the same moment, it rebuilds on top of the other person's commit instead of overwriting it.
- Shows who uploaded each photo and when, using the file name `date__login__name.jpg`.
- Search, newest/oldest sorting, and a full-screen viewer with arrow keys and swipe.
- Download one photo, or select several (or all) and get a ZIP.
- Checks for new photos every 60 s while the tab is open. It uses ETags, so unchanged checks don't count against the GitHub rate limit.
- Read-only users see no upload or delete controls.
- Signing out clears the token and the cached previews.

## Limits to know

- **Size:** GitHub recommends repos stay under **1 GB** (the page shows usage), and single files are capped at 100 MB (the page stops at 50 MB). With Optimize on, a typical phone photo is about 0.5–1.5 MB, so roughly 1,000+ photos.
- **Deletes aren't permanent:** a deleted photo stays in the git history. Fully purging it means rewriting history, for example with `git filter-repo`.
- **HEIC (iPhone):** Safari converts it to JPEG during Optimize. In Chrome/Edge on Windows, HEIC uploads as-is with no preview, but it can still be downloaded.
- **Tokens expire.** When one does, the page sends that person back to the sign-in screen.
