# 📻 Home Chat

A private, Viber‑style messenger for your family: Android phones and Windows PCs.
**No servers to run.** Everyone tunes in to the same secret **frequency**, like walkie‑talkies,
and the app does the rest:

- **Same Wi‑Fi?** Devices find each other and talk directly. Works even with the internet down.
- **Apart?** Encrypted messages travel through free public relays (Nostr) and wait there up to 7 days.
- **Off for longer than a week?** Your device catches up from the others when it sees them again
  (over Wi‑Fi, or by asking an online device over the relays).

Everything is end‑to‑end encrypted. Relays, Wi‑Fi neighbours and anyone else without the
frequency see only random bytes. Inside a frequency, direct messages and groups are encrypted
again so only their members can read them.

```
   Phone ──── same Wi‑Fi (direct, UDP discovery + HTTP) ──── PC
     │                                                        │
     └──── public relays (wss://…, encrypted, 7‑day hold) ────┘
        calls: WebRTC directly between devices
```

## Features

| | |
|---|---|
| **Chats** | the frequency's group chat, 1:1 chats, groups, "My Notes", search |
| **Messages** | text, emoji, stickers (built‑in packs + your own), photos, GIFs, videos, files, voice messages |
| **Viber touches** | ✓ sent / ✓✓ delivered / blue ✓✓ seen, "seen by", typing…, online / last seen, reactions (double‑tap ❤️), reply, forward, edit, delete for everyone / for me, pin |
| **Calls** | voice and video, 1:1 and group (up to ~6), join a call in progress |
| **Privacy** | end‑to‑end encryption, disappearing messages, security codes |
| **Groups** | name, add/remove people, admins, leave |
| **Updates** | the apps update themselves from your GitHub releases |

## Project layout

```
messenger-chat-app/
├── app/                          Flutter app (Android + Windows)
│   ├── lib/
│   │   ├── crypto/               frequency keys, end-to-end encryption, relay signatures
│   │   ├── net/                  relays, Wi-Fi peers, sync
│   │   ├── state/                chats, calls
│   │   └── ui/                   screens
│   ├── test/                     encryption test vectors (checked against a reference)
│   ├── tool/                     platform patches, version + signing helpers
│   └── setup.ps1                 one-command install + build
└── app/tool/release-workflow.yml  GitHub Actions: builds + publishes releases (copy to .github/workflows/)
```

---

## 1 · Build

On Windows (it installs Flutter and anything else missing, asking first):

```powershell
cd app
.\setup.ps1              # Windows app + Android APK
.\setup.ps1 -Run         # just run it on this PC
```

Outputs:
- `app\build\windows\x64\runner\Release\`: copy the whole folder somewhere you can write to,
  like `Documents\Home Chat` (**not** Program Files, or auto‑update can't replace the files).
- `app\build\app\outputs\flutter-apk\app-release.apk`: send it to each phone and install it.

The first Android build creates a **signing key** (`app\android\key.properties` and
`app\android\app\homechat-release.jks`). Back these two files up somewhere safe, and never put
them in Git. Every future version must be signed with them, or phones refuse to update.

## 2 · Get the family on a frequency

1. Open the app, enter your name.
2. Tap 🎲 to make a frequency (or type your own, long and unguessable), then **Tune in**.
3. Tell the others the frequency **in person** (or over a private channel). Anyone who has it can join.
4. They install the app, enter their name and the same frequency. Everyone appears in each other's
   chat list within a few seconds.

To use your account on a second device: **More → Link another device** shows an account code.
Type it into the other device's welcome screen.

If the frequency ever leaks: **More → Frequency → Change frequency**, and tell everyone the new one.

### Phone notifications while the app is closed

Phones can't keep a connection open forever, so when Home Chat is fully closed the others' apps
send you a ping through the free **ntfy** app. The ping says only who wrote, never what.
**More → Phone notifications**: turn it on, install ntfy, tap **Subscribe in ntfy**.
(It uses the public `ntfy.sh` by default; you can point it at your own ntfy server.)

---

## 3 · Releases and auto‑update

The apps check `https://github.com/<you>/<repo>/releases/latest` every few hours (and in
**More → App updates**). If the version there is newer:

- **Windows** downloads `HomeChat-windows-x64.zip`, closes, replaces its files and restarts.
- **Android** downloads `HomeChat-android.apk` and opens the installer. Android always asks you
  to tap *Install*, and the first time it asks you to allow installs from Home Chat.

### One‑time setup

1. Create the GitHub repository. It must be **public**, because the apps download releases
   without logging in. (Keep the frequency out of the repo. Nothing secret is in the code.)
2. Put its name in `app/lib/config.dart`:
   ```dart
   const updateRepo = 'your-github-name/messenger-chat-app';
   ```
3. Put the release workflow where GitHub looks for it, then push this folder:
   ```powershell
   cd C:\Users\Kenneth\Documents\messenger-chat-app
   New-Item -ItemType Directory -Force .github\workflows | Out-Null
   Copy-Item app\tool\release-workflow.yml .github\workflows\release.yml
   git init -b main
   git add .
   git commit -m "Home Chat 2.0"
   git remote add origin https://github.com/your-github-name/messenger-chat-app.git
   git push -u origin main
   ```
4. Give GitHub the Android signing key (needs the GitHub CLI: `winget install GitHub.cli`, then `gh auth login`):
   ```powershell
   cd app
   .\tool\github-secrets.ps1 -Repo your-github-name/messenger-chat-app
   ```
5. Rebuild and reinstall once with the new `updateRepo` (`.\setup.ps1`), so the installed apps
   know where to look. If a phone already has an APK signed with a different key, uninstall it first.

### Every release

```powershell
git commit -am "What changed"
git tag v2.1.0
git push origin main v2.1.0
```

GitHub Actions builds both apps (about 15 minutes), names them correctly and publishes the release.
The version in the app comes from the tag. You can also start it from the **Actions** tab
(*Release → Run workflow* and type a version).

---

## How it works (for the curious)

- **Frequency → keys.** The frequency is stretched (PBKDF2, 100k rounds) into a channel key
  (AES‑256‑GCM) and a public lookup tag. Every packet on the frequency is encrypted with the
  channel key.
- **People.** Each person has an X25519 key pair (their user id is a hash of the public key).
  Messages in a chat are additionally sealed for that chat's members only, so a frequency
  member who isn't in your 1:1 chat or group can't read it.
- **Relays.** Packets are posted as Nostr events (kind 4747 stored, 24747 live‑only) tagged with
  the lookup tag and an `expiration` of at most 7 days, signed with a per‑person key (BIP‑340).
  The default relays are in `lib/config.dart` and editable in **More → Frequency**.
- **Wi‑Fi.** UDP broadcast on port 45454 announces "I'm on this frequency" (encrypted); devices
  then exchange packets and files over a small HTTP server on a random port.
- **History.** Each device keeps every packet it has seen (`packets.jsonl`, still encrypted).
  That's what it shares when another device needs to catch up.
- **Files.** Encrypted with their own key. Up to 8 MB they also go through the relays in pieces;
  bigger ones transfer directly over Wi‑Fi.
- **Calls.** WebRTC, devices connect directly. Signaling goes through the same encrypted channel.

## Limits and good to know

- People see a chat's history from when they joined. Messages sent before someone tuned in
  weren't encrypted for them.
- Files over 8 MB only arrive when sender and receiver are on the same Wi‑Fi at some point.
- Calls between two different networks can fail on some mobile/office networks that block direct
  connections (no relay server for calls). On the same Wi‑Fi they always work.
- Public relays are run by volunteers. If one goes away, the others keep working, and you can add more.
- Windows asks once to allow Home Chat through the firewall: allow it on **private** networks for Wi‑Fi direct.
- iPhone isn't set up.

## Troubleshooting

- **Others don't appear:** check the frequency is exactly the same (case and extra spaces don't
  matter; everything else does). **More → Frequency** shows relays and Wi‑Fi devices.
- **"Not connected":** no internet and nobody on the same Wi‑Fi. Messages wait and send later.
- **Phone doesn't find the PC on Wi‑Fi:** allow Home Chat in the Windows firewall for private
  networks, and make sure your Wi‑Fi is set to *Private* in Windows.
- **Update fails on Windows:** the app folder must be somewhere writable (Documents, Desktop).
