# Subs Tracker — Project Notes

## What Is This
A native macOS app (SwiftUI + SwiftData) to track all your subscriptions in one place. Special focus on AI services — Claude Code usage is read directly from local files, OpenAI via API.

## Key Decisions

### Why local file reading for Claude?
You're on a personal Claude Max plan with no Admin API access. But since this is a Mac app, we can read `~/.claude/stats-cache.json` directly — no API key needed. This is the main advantage of going native.

### Why no App Sandbox?
The app needs to read files from `~/.claude/` and access the macOS Keychain freely. Sandboxing would require additional entitlements and complicate filesystem access. Since this is a personal app (not App Store), sandbox is disabled.

### Architecture: MVVM + Services
- **Models**: SwiftData `@Model` classes (Subscription, UsageRecord)
- **ViewModels**: `@Observable` classes for each major view
- **Services**: Singleton services for data access (Claude local files, OpenAI API, Keychain)
- **SubscriptionManager**: Coordinates data refresh across all services

### SwiftData enum storage
SwiftData doesn't natively support enums well, so enums are stored as raw String values with computed properties for type-safe access.

## File Structure
```
SubsTracker/
├── App/SubsTrackerApp.swift        — Entry point + main NavigationSplitView
├── Models/                          — SwiftData models + enums
├── Services/                        — Data access layer
│   ├── ClaudeCodeLocalService       — Reads ~/.claude/stats-cache.json
│   ├── OpenAIUsageService           — Fetches from OpenAI Usage API
│   ├── KeychainService              — Stores API keys in macOS Keychain
│   └── SubscriptionManager          — Coordinates all services
├── ViewModels/                      — Business logic for views
└── Views/                           — All SwiftUI views
```

## Claude Stats Cache Format (v2)
The file at `~/.claude/stats-cache.json` contains:
- `dailyActivity[]` — date, messageCount, sessionCount, toolCallCount
- `dailyModelTokens[]` — date + tokensByModel (model name → token count)
- `modelUsage{}` — per-model aggregates: inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens
- `totalSessions`, `totalMessages`, `firstSessionDate`

Models seen: `claude-opus-4-6`, `claude-opus-4-5-20251101`, `claude-sonnet-4-5-20250929`

## Build
```bash
cd "$HOME/Projects/iOS/Subs tracker"
xcodegen generate
xcodebuild -scheme SubsTracker -destination 'platform=macOS' build
```

## What's Working (v1.0)
- Dashboard with monthly cost summary and pie chart
- Sidebar navigation with subscription list grouped by category
- Add/edit/delete subscriptions with full detail view
- Claude Code usage view reading real data from local files
- OpenAI usage view with API key management (Keychain)
- Settings view with configurable data path, refresh interval, currency
- Swift Charts for token usage and daily activity visualization
- Auto-refresh on app launch

## Future Ideas
- Menu bar presence (quick glance at spend)
- Notifications before renewal dates
- CSV/JSON export of usage data
- iCloud sync for subscription data
- Per-session breakdown from Claude JSONL files
- Budget alerts when approaching spending limits
