### Cloud sharing and links (shelf)

Select files on the shelf, choose **Share link…** and pick a service: Cocaine uploads them (several files or a folder are
zipped first with `ditto`), puts the link on the clipboard and shows it under the shelf with **Copy link**, **Open** and
**Revoke**. The upload runs as a shelf job, with a progress bar and **Cancel**.

You set the services up in **Settings → Island → Sharing**. Nothing is set up for you, no public host is built in, and
nothing is ever uploaded without a click: watched folders, instant actions, links and the command line never upload.

#### Services

| Service | How | Link | Revoke |
|---|---|---|---|
| **S3-compatible**: Amazon S3, Cloudflare R2, Backblaze B2, Wasabi, DigitalOcean Spaces, MinIO | Your endpoint, region, bucket and keys. A signed PUT (AWS Signature V4, written with CryptoKit), streamed from the file. Files over 100 MB go up in parts (multipart); a cancelled or failed one is aborted so no half upload stays in the bucket. Up to 50 GB. | A **presigned** link that expires (1 h, 24 h — the default —, 3 days or 7 days, the most S3 allows), or a link under your **public address** (a public bucket, r2.dev or your own domain), which doesn't expire. | Deletes the object: the link stops working. |
| **Nextcloud / ownCloud** | Your server, user name and an **app password**. The file goes into a folder (default *Cocaine*, made if missing) over WebDAV. Up to 4 GB. | A public, read-only share link made with the OCS share API, with an optional link password and expiry (1, 7 or 30 days, or never). | Deletes the share, then the file. |
| **WebDAV** (any server: Synology, Apache, Fastmail…) | The folder's WebDAV address, user name and password. Up to 4 GB. | Your public address for that folder + the file's name; without one, the WebDAV address itself (it asks for your login). | Deletes the file. |
| **SFTP** (your server) | `/usr/bin/sftp` with **keys only**: your ssh-agent or a key file. Up to 50 GB. | The public web address of the remote folder + the file's name. | Removes the file. |
| **Your own upload command** | A command line you write (curl or a script) that uploads `{file}` and prints the link. Up to 2 GB. | The first https link it prints, a regular expression or a JSON path. | Not possible (the service decides). |

Not built: Google Drive, OneDrive and iCloud Drive links (they need the maintainer's app registration with Google or
Microsoft, or CloudKit with an Apple developer account), Imgur and link shorteners (third-party tracking), anonymous public
hosts (0x0.st, file.io, transfer.sh, Litterbox) — Litterbox is only offered as an editable *preset* for your own command,
with a warning. **Dropbox** isn't built either: a clean version needs each user to register their own Dropbox app and a
loopback OAuth listener (a listening port), which this app doesn't open; you can still upload to Dropbox with a script of
yours as *your own upload command*.

#### Setting up

**Add…** offers the S3 presets (the endpoint shape and region filled in), Nextcloud, WebDAV, SFTP, your own command and its
presets (Zipline, your own endpoint, a script, Litterbox). Each service has **Test connection**: it uploads a tiny generated
file, opens its link (S3 presigned links), and deletes it again. The switch next to each service hides it from the shelf;
the **Cloud sharing** switch at the top turns everything off.

- **S3 / R2**: make an access key that can only write to (and delete from) that one bucket. R2's endpoint is
  `https://<account-id>.r2.cloudflarestorage.com` with region `auto`. Objects are named
  `<prefix>/<32 random hex characters>/<safe name>`, so links can't be guessed. *Path-style addresses* is on for R2, B2 and
  MinIO; turn it off for AWS and Spaces if your bucket wants `bucket.endpoint`.
- **Unsigned payloads**: the body is sent with `x-amz-content-sha256: UNSIGNED-PAYLOAD` (allowed over TLS) so a big file is
  streamed without being read twice. If a store refuses that, Cocaine hashes the file and sends it again, and remembers to
  hash for that service from then on. Parts of a multipart upload are always hashed.
- **Nextcloud**: make an app password in Settings → Security → Devices & sessions.
- **SFTP**: the server must already be in `~/.ssh/known_hosts` (connect once with `ssh` in Terminal and check the key):
  Cocaine runs `sftp` with `BatchMode=yes`, `StrictHostKeyChecking=yes`, password and keyboard-interactive logins off. The
  remote folder must exist.
- **Your own command**: placeholders are `{file}` (required), `{name}`, `{mime}`, `{size}`, `{secret_headers}`. Example:
  `/usr/bin/curl -sS --fail -H @{secret_headers} -F "file=@{file}" https://upload.example.com/`. It runs only after you
  allowed that exact command (and the script it names); it asks again when either changes.

#### Privacy and security

- **Secrets** (S3 keys, passwords, tokens, secret headers) are in the Keychain, service `local.cocaine.share`, one item per
  service, readable only while the Mac is unlocked, on this Mac only, never synced. The settings file
  (`~/Library/Application Support/Cocaine/share/providers.json`, 0600) has no secret. A secret field shows "Saved in the
  Keychain" and is never shown again; typing replaces it. Removing a service deletes its Keychain item.
- **TLS only**: every address must be `https://` (plain `http://` only to this Mac, for a local MinIO). An address with a user
  name or password inside is refused. Redirects are never followed with your credentials. Answers are bounded.
- **Every upload is a click.** New services ask **before every upload** (where the files go and how long the link works);
  you can turn that off per service. Your own command also asks before its first run.
- **Links are passwords.** Anyone with a link can download the file until it expires or you revoke it. Links are put on the
  clipboard as an ordinary copy (since 2.9; before, marked *concealed*, which can also keep a copy away from your other devices):
  Cocaine's own clipboard history doesn't keep them; other clipboard apps and Universal Clipboard treat them as any copy.
- **Nothing logs** secrets or signed URLs; error messages name the host at most.
- **File names** are made safe for keys and paths (letters, digits, `.`, `_`, `-`); the display name is kept in the history.
  Content-Type comes from the file's type.
- **Your own command** runs with no shell: the line is split into arguments, the placeholders filled in each argument, and
  the file handed over as a link with a safe name in a private temporary folder, so a name like `$(rm -rf ~)` or `-o x` is a
  harmless path. It gets a small environment of its own, a 5-minute timeout (adjustable in the settings file) and bounded
  output; the secret headers go in a 0600 temporary file (`{secret_headers}`, also `$COCAINE_SECRET_FILE`), never in the
  arguments or the environment.
- **History** (`share/history.json`, 0600, at most 200 entries): file name, size, service, date, expiry and link — never the
  file. **Remove expired** drops expired and revoked links; entries can be removed one by one or cleared.

#### Custom actions: webhooks, keys, chains, import/export

- **Webhook** (Settings → Island → Shelf → Your actions → Add… → Webhook): POST or PUT the selected files (one request each,
  with `X-Cocaine-Filename`) or their details as JSON (names, sizes, types, dates; no paths) to your https address. A secret
  header (e.g. `Authorization: Bearer …`) is kept in the Keychain. It asks before its first run and again when the address,
  method or body changes. The answer can go to the clipboard or the shelf like any action's output.
- **Keys**: give an action ⌥1…⌥9; while the shelf has the keyboard, that key runs it on the selection (or the whole
  collection).
- **Then**: an action can hand its result to another one — the files it printed (one path per line) or moved, else the same
  files. At most 4 steps, never in a loop; each action still asks before its own first run.
- **Import… / Export…** saves the actions as JSON without approvals or secrets; imported actions get new ids, keep their
  chains, drop keys already in use, and ask before each first run.

#### Limits

- Checked against local fake servers only (`--cloud-test`): S3's SigV4 against AWS's published examples, PUT, multipart,
  presigned links, the unsigned-payload fallback, WebDAV, the Nextcloud share API, SFTP's arguments (never run against a
  host). Not yet tried against the real R2, B2, Wasabi, Spaces, Nextcloud or an SFTP server: whether each store accepts
  UNSIGNED-PAYLOAD is handled by the automatic fallback.
- At most 100 files per upload (several are one ZIP, so one link). Uploads run one at a time with the shelf's other jobs.
- No resumable uploads; a cancelled S3 multipart upload is aborted, an SFTP upload that is cancelled, times out or fails
  half-way is removed, an interrupted WebDAV PUT leaves nothing on most servers. An SFTP upload may take an hour, or longer
  for a big file (at least 1 MB/s is expected).
- **Revoke** deletes the file where it was uploaded: if the service's bucket, folder or server changed since, Cocaine says so
  instead of deleting nothing (delete the file on the service itself). Cancel stops the uploader's whole command, including
  programs its script started.
- The SFTP service doesn't use the SSH hosts list of the remote-sessions feature yet; its server is entered here.
