# SubsTracker — Project Rules

## Build Verification
After editing any Swift file, ALWAYS build the project using XcodeBuildMCP to verify there are no compilation errors before moving on to the next task. Never assume code compiles — verify it.

## Project Context
- Native macOS app (SwiftUI + SwiftData + Swift Charts)
- macOS 14.0+, Swift 5.9
- Zero external dependencies — all Apple frameworks
- XcodeGen for project generation (project.yml → .xcodeproj)
- No App Sandbox (needs filesystem + Keychain access)

## Architecture
MVVM + Services layer. Follow existing patterns:
- Models in `SubsTracker/Models/` — SwiftData `@Model` classes
- Services in `SubsTracker/Services/` — singleton services for data access
- ViewModels in `SubsTracker/ViewModels/` — `@Observable` classes with `@MainActor`
- Views in `SubsTracker/Views/` — SwiftUI views organized by feature

## SwiftData Notes
- Enums stored as raw String values with computed properties (SwiftData limitation)
- Use `FetchDescriptor` with manual filtering for optional predicates
- Schema defined in `SubsTrackerApp.swift`

## Apple Documentation
Use the apple-docs MCP to look up SwiftUI, SwiftData, Swift Charts, and Security framework APIs before writing code. Don't rely on memory — check the docs.

## When Adding New Files
If you add new Swift files, also update `project.yml` if needed, then regenerate the Xcode project with `xcodegen generate`.