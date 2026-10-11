// App-wide defaults. Most can be changed in Settings.

/// Public Nostr relays that carry the (encrypted) packets. Any that accept
/// custom event kinds work; you can add your own in Settings > Frequency.
const defaultRelays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://relay.nostr.band',
];

/// STUN servers help calls find a direct path between two networks.
const defaultIceServers = [
  {'urls': 'stun:stun.l.google.com:19302'},
  {'urls': 'stun:stun.cloudflare.com:3478'},
];

/// Where phones get notified when the app is closed (only "who wrote", never the message).
const defaultNtfyServer = 'https://ntfy.sh';

/// GitHub repository that publishes releases, as "owner/repo".
/// Releases need these assets: HomeChat-windows-x64.zip and HomeChat-android.apk
/// (the release workflow in .github/workflows/release.yml makes them).
const updateRepo = 'kenntamad/homechat-release';
