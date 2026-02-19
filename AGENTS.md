# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Runtime Viewer is a macOS/iOS application for inspecting Objective-C and Swift runtime interfaces. It serves as a modern alternative to RuntimeBrowser with features like Swift interface support, type-defined jumps, Xcode-style syntax highlighting, and code injection capabilities.

## Build Commands

```bash
# Debug build (x86_64 and arm64e)
./BuildScript.sh

# Or directly via xcodebuild
xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS'

# Release archive (builds Catalyst helper first, then main app)
./ArchiveScript.sh
```

## Architecture

### Package Structure

The project uses two Swift Package Manager packages:

**Core Package** (`Core/`):
- `RuntimeViewerCore` - Runtime inspection engine using ClassDumpRuntime (ObjC) and MachOSwiftSection (Swift)
- `RuntimeViewerCommunication` - XPC-based IPC layer for cross-process inspection
- `RuntimeViewerObjC` - Objective-C interop utilities

**RuntimeViewerPackages** (`RuntimeViewerPackages/`):
- `RuntimeViewerArchitectures` - MVVM + Coordinator pattern with RxSwift
- `RuntimeViewerApplication` - ViewModels and business logic (Sidebar, Inspector, Content, Theme, FilterEngine)
- `RuntimeViewerUI` - AppKit UI components (MinimapView, StatefulOutlineView, skeleton effects)
- `RuntimeViewerService` - XPC service helpers and code injection

### Application Targets

- `RuntimeViewerUsingAppKit` - Main macOS application (AppKit)
- `RuntimeViewerServer` - XPC background service for inter-process communication
- `RuntimeViewerCatalystHelper` - Mac Catalyst support bridge
- `RuntimeViewerUsingUIKit` - iOS variant (secondary)

### Key Architectural Patterns

- **MVVM-C (MVVM + Coordinator)**: Navigation via CocoaCoordinator (macOS) / XCoordinator (iOS)
- **Reactive Streams**: Heavy RxSwift usage for UI state and data flow
- **Dependency Injection**: Uses swift-dependencies for service injection
- **Multi-Process**: XPC services enable safe inspection of external processes

### UI Technology Stack

- **AppKit**: All UI components except Settings
- **SwiftUI**: Settings module only

## Development Guidelines

When adding new features, you **MUST** follow these rules:

1. **UI Framework**: Use AppKit for all new UI components (except Settings-related features which use SwiftUI)
2. **Architecture**: Follow MVVM-C pattern
   - **Model**: Data structures and business logic
   - **View**: AppKit views (NSView, NSViewController)
   - **ViewModel**: RxSwift-based, handles UI state and logic
   - **Coordinator**: Manages navigation and flow
3. **Reactive**: Use RxSwift for data binding and event handling
4. **No SwiftUI** in non-Settings areas - keep the codebase consistent

### Platform Requirements

- Swift 6.2, Xcode 15+
- Core: macOS 10.15+, iOS 13+
- Main App: macOS 14+, iOS 17+

## Key Source Locations

- Main app entry: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift`
- Coordinator/navigation: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift`
- Runtime engine: `Core/Sources/RuntimeViewerCore/RuntimeEngine.swift`
- ViewModels: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/`

## MCP Tool Preferences

When MCP servers are available, **MUST** prefer them over shell commands and built-in tools:

### Xcode MCP (Project Operations)
Prefer Xcode MCP tools for all Xcode project-level operations:
- **File reading**: Use `XcodeRead` instead of `Read` / `cat` for files in the Xcode project
- **File writing**: Use `XcodeWrite` instead of `Write` for creating/overwriting files in the project
- **File editing**: Use `XcodeUpdate` instead of `Edit` / `sed` for modifying files in the project
- **File searching**: Use `XcodeGrep` instead of `Grep` / `grep` for searching in project files
- **File discovery**: Use `XcodeGlob` / `XcodeLS` instead of `Glob` / `ls` for browsing project structure
- **File management**: Use `XcodeMakeDir`, `XcodeMV`, `XcodeRM` for directory/file operations
- **Build**: Use `BuildProject` for building the project through Xcode
- **Tests**: Use `GetTestList`, `RunSomeTests`, `RunAllTests` for test operations
- **Diagnostics**: Use `XcodeRefreshCodeIssuesInFile`, `XcodeListNavigatorIssues` for checking issues
- **Preview**: Use `RenderPreview` for SwiftUI preview rendering
- **Snippets**: Use `ExecuteSnippet` for running code snippets in project context
- **Documentation**: Use `DocumentationSearch` for searching Apple Developer Documentation

### Priority Order
1. **Xcode MCP** — for project file operations, in-editor builds, diagnostics, and previews
2. **RepoPrompt** — for cross-repo context building, code structure analysis, and git operations
3. **Built-in tools** — fallback when MCP tools are unavailable or not applicable

## External Dependencies

Core reverse engineering powered by:
- [ClassDumpRuntime](https://github.com/MxIris-Reverse-Engineering/ClassDumpRuntime) - ObjC runtime introspection
- [MachOSwiftSection](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection) - Swift interface extraction
- [MachInjector](https://github.com/MxIris-Reverse-Engineering/MachInjector) - Code injection (requires SIP disabled)
