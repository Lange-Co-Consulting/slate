# Security model

Slate runs models and coding tools with the privileges of the signed-in user.
It is a local developer tool, not a hardened container or VM.

## Permission modes

New code conversations default to **Ask**. Every file write and shell command
requires approval. **Edits** allows file writes inside the selected project but
still confirms shell commands and destructive file changes. **Auto** uses
Slate's risk classifier for local tools and Claude Code's native `auto` policy
for Claude turns. Workspace-scoped reads and small ordinary edits may run
automatically; local shell commands and sensitive or deletion-heavy changes
still require approval.

True unattended execution is guarded by a second, global checkbox at
**Settings → Security → Skip permissions in Auto mode**. It defaults off, is
not enabled by imported settings, and only affects Auto. Ask remains Ask even
when the checkbox is enabled. "Allow for this session" is scoped to the exact
path or command and risk level; destructive approvals are never remembered.

File read/write tools canonicalize paths and reject paths outside the selected
project, including symlink escapes. Shell commands run in a macOS Seatbelt
sandbox with only the selected workspace and a fresh private scratch directory;
networking, the rest of the home directory and inherited secrets are denied.
The shell starts without loading startup files and permanently blocks direct
deletion, destructive Git, privilege escalation, process termination and common
network-transfer commands. Those blocks remain active when Skip permissions is
enabled. Git status/diff/stage/commit uses the same constrained model and
disables repository hooks, external diffs, filters and fsmonitor helpers.
Claude Code runs
in safe mode (project/user hooks, plugins and MCP servers disabled) and receives
matching Bash-tool denials. OpenCode runs in pure JSON mode with a runtime
permission map derived from Slate's Ask, Edits or Auto mode. It denies external
directories, web tools, deletion, destructive Git, privilege escalation,
process termination and network-transfer shell commands. Its dangerous bypass
flag is passed only when Auto and the global Skip permissions checkbox are both
active; explicit denials remain in the runtime map.

The blocklists are defense in depth, not a VM: an allowed command can still
damage the selected workspace, and native model/parser vulnerabilities are not
contained by a separate virtual machine. Do not enable Skip permissions for an
untrusted repository, model or prompt. Use a VM/container for hostile code.

Claude Code and OpenCode are optional and send relevant conversation/task data
to their configured providers. Local model downloads likewise contact their
configured model host. Ordinary local inference, memory, speech and image
generation do not intentionally upload user content. Custom OpenAI-compatible
endpoints must use HTTPS; plain HTTP is accepted only for loopback hosts.

User-added MCP servers are deliberately narrower than the coding shell. Slate
supports local executable + stdio transport only; HTTP and SSE are rejected.
Each process is launched through a macOS sandbox profile that denies network
access and restricts files to the explicitly selected working directory plus a
fresh private scratch directory. Every call is shown in the approval sheet
(including its arguments), request/response sizes are capped, and only the
server/tool/argument tuple can be remembered for the current session. MCP output
is capped before it reaches the model and outcomes are written to the
metadata-only audit log. A server can still alter its selected directory, so
install only binaries you trust and use the per-call preview as the primary
boundary.

`slatectl ask` uses UUID-named files below Slate's Application Support folder
and a custom URL containing only the UUID. Requests are size-limited and stored
with owner-only permissions; prompt text is never placed in a URL. Apple
Shortcuts passes it over stdin, keeping it out of the process list. The command
refuses cloud engines and requires a loaded local model.

The macOS Services entry accepts selected text or file URLs from another app
and places them into Slate's local composer. It does not send service content
over the network. Diagnostic OSLog messages mark model and user-derived error
text as private.

## Local data, downloads and updates

Slate-owned Application Support directories and files use owner-only modes
(0700/0600), reject symbolic-link destinations, and enforce bounded reads. A
full data deletion also clears Slate's Keychain records. Project rules and local
skills are inert until the user trusts their exact content digest; changing a
file requires a new confirmation.

Remote model browsing and downloads are off by default. When explicitly enabled,
transfers use HTTPS, no persistent cookies/cache, validated filenames, exact
response sizes and basic model-format checks before native loaders see a file.
Image, Office, audio and knowledge imports have regular-file, size, pixel,
archive-entry and total-index limits; Office archive extraction runs in a
network-denied sandbox.

**Settings → Network Access → Silent Mode** is a master gate for Slate's own
network clients. It cancels active model/image transfers and cloud connectors,
and blocks new update, licence, Hugging Face, optional voice-model and cloud
requests. Individual settings are retained for later, while the resident local
model and local data keep working. It is not a system-wide firewall: links open
in another app, and arbitrary commands the user explicitly approves, are outside
the built-in client gate.

The updater is disabled until a release build contains a pinned Ed25519 public
key. It accepts only an HTTPS manifest whose canonical payload has a valid
signature, verifies the DMG SHA-256, then checks the replacement app's
designated requirement and Developer ID team before installation. Redirects,
credentials in URLs and unbounded helper-process output are rejected.

## Hardened runtime & library validation

The bundled native frameworks and tools are individually signed with the same
identity as the app; library validation is enabled (Slate does **not** carry the
broader `disable-library-validation` entitlement). The public app also carries
neither `allow-jit` nor `allow-unsigned-executable-memory`: Slate does not create
executable memory itself, and local llama.cpp/diffusion inference is part of the
physical release smoke test. A self-signed developer build uses a separate local
entitlement only for library validation because a local certificate has no Apple
Team ID. A public release must co-sign every embedded framework under one
Developer ID Team, be notarized and be tested with hardened runtime enabled.

## Reporting

Report vulnerabilities privately to info@lange-co-consulting.de with the subject
“Slate security report”. Do not include secrets or personal data until a secure
exchange has been agreed. Native framework artifacts are checksum-locked by the
release scripts. Public releases must be Developer ID signed, notarized and
stapled; the packaging script supports this through `SLATE_SIGN_IDENTITY` and
`SLATE_NOTARY_PROFILE`.
