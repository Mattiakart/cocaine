### SSH hosts: AI agents on remote machines

Settings → AI → **SSH hosts**. Claude Code, Codex, Gemini CLI, Qwen Code and Cursor's CLI running on a server you reach with ssh
show up in Cocaine like local ones: in the agents list (tagged with the host's name, e.g. *api · Dev box*), in alerts (flash,
sound, voice, the phone), and in the notch's review of plans, questions and permission requests — answered from the Mac, the answer
going back to the remote agent. Called "SSH hosts" so it isn't confused with *Remote*, which is the iPhone feature.

**How it works.** No port is opened, on the Mac or on the host, and nothing runs there as a service:

- Cocaine runs your own `/usr/bin/ssh` (so `~/.ssh/config`, ProxyJump, your keys and ssh agent work as in Terminal), one connection
  per host, with the host's key always checked against `known_hosts` (never `StrictHostKeyChecking=no`), no password prompt
  (BatchMode), no agent, X11 or port forwarding even if your config asks for them, and keepalives.
- On the host it runs a small **relay** (`~/.cocaine/bin/cocaine-relay`, a perl script shipped inside Cocaine.app; perl with
  JSON::PP and Digest::SHA is needed — standard on most Linux, macOS and BSD systems). It lives only while Cocaine's connection does
  and talks to the Mac only through that ssh connection, in signed lines.
- The AI tools' hooks there run the relay, which hands their news (and their requests, waiting for your answer) to the Mac.
  If the Mac isn't connected, a hook prints nothing and the tool asks in its own terminal as usual; nothing is ever decided there.

**Adding a host.** *Add host…* offers the `Host` names of your `~/.ssh/config` (and files it includes) and of `known_hosts` —
only read, nothing connected — or type `user@host` (with `:port`). Then, after your OK, **Install relay…** copies the relay and
a key to `~/.cocaine` there (0700; the key 0600) through ssh's input (the key never appears in a command line). Then **Review
hooks…** shows, file by file, exactly what would change in the AI tools' settings there (`~/.claude/settings.json`,
`~/.codex/hooks.json`, `~/.gemini/settings.json`, `~/.qwen/settings.json`, `~/.cursor/hooks.json`); nothing is written until you
press **Change these files**. Only Cocaine's own entries are added (your other hooks and settings stay as written), each file is
replaced only if it hasn't changed since it was read, a backup is kept in `~/.cocaine/backup`, and if one file can't be written the
ones already changed are put back. Running it again changes nothing. Codex asks once to trust new hooks: run `/hooks` there.
Approval requests from Claude Code are added only when the relay could read its version there (2.0.45 or newer; plans and questions
2.1.78 or newer).

**Connections.** Each host shows a dot and its state: connected (with the tools that have hooks), connecting, unreachable (tried
again with a growing wait from 2 seconds to 5 minutes, sooner after the Mac wakes or the network changes), or stopped with the reason:

- *The host's key has CHANGED* — Cocaine refuses to connect. If you expected it, fix `~/.ssh/known_hosts` in Terminal, then Retry.
- *The host's key isn't known yet* — connect once in Terminal (`ssh <host>`) to check and accept it.
- *The login was refused* — keys, ssh agent, or a login that needs you (MFA, a password): **Log in in Terminal** opens one master
  connection there (`ssh -M`, kept 8 hours); Cocaine then connects through it.
- *No perl*, *relay missing*, *another key* — install the relay again.

An older relay is replaced automatically by the app's own (the version is checked at each connection). While a host is
unreachable its sessions stay in the list marked *host unreachable* (for up to 6 hours) instead of disappearing; news that happened
meanwhile (only which session started, finished or ended — never any text) is kept on the host and brings the list up to date when
the connection is back. The relay is asked every minute whether each remote session's process still runs.

**Going back to a session** on a host goes to the Terminal or iTerm2 tab that holds your ssh connection to it (found from the
session's `SSH_CONNECTION`: the local ssh process with that port, then its terminal), and selects the tmux pane there if it runs in
tmux. If that tab isn't found (a jump host, NAT that changes ports, or ssh started by another app such as VS Code's Remote-SSH), a
terminal app comes forward and Cocaine says so.

**Kill switches and removal.** The card's main switch closes every connection; each host has its own switch. *Remove…* removes a
host from Cocaine only, or (when connected) also takes Cocaine's hooks and `~/.cocaine` off it. If the host can't be reached, remove
it there by hand: `rm -rf ~/.cocaine` and Cocaine's lines (marked `# cocaine://alert`) in the files above.

**Security.**
- Each host has its own random 256-bit key, kept in your login Keychain (this Mac only) and in `~/.cocaine/relay.key` on the host.
  Every line in both directions carries an HMAC-SHA256: the Mac's lines and the relay's are tied to a fresh challenge per connection
  and to growing sequence numbers (no replay); each hook signs its own request and accepts only an answer signed over its own random
  id and nonce. Anything unsigned, malformed, repeated or too long is refused; banners printed by the remote shell are ignored; a host
  that floods is rate-limited.
- Host names are checked (letters, digits and `. _ @ : -`, never starting with `-`) and always given to ssh as their own argument
  after `--`; the commands run there are fixed strings (no host name, path or text of yours inside).
- What Cocaine receives from a host is treated like a local hook's input: bounded, cleaned, and only granted when the whole request
  was shown. A remote session never names anything on your Mac (no folder, process or terminal of the Mac comes from it).
- An audit log (*Log*) records when hosts connected, what was installed or changed, and the kind of each request and answer — never a
  command, a plan, a message or a file's content.
- The host's own account (and its administrators) can of course see and fake anything that runs there: Cocaine trusts a host exactly
  as much as you trust your ssh login to it. One Mac per remote account: a second Mac connecting takes over the relay.

**Not done / limits.** Claude's plan limits from a remote statusline aren't read. Copilot, OpenCode and Windsurf hooks aren't put
on hosts. A host where Cocaine itself runs (another Mac) is left alone. Remote approvals were tested end to end with a stand-in for
ssh and the real relay on this Mac, not against a real remote server.
