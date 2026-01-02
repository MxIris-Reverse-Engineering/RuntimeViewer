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

- **MVVM + Coordinator**: Navigation via CocoaCoordinator (macOS) / XCoordinator (iOS)
- **Reactive Streams**: Heavy RxSwift usage for UI state and data flow
- **Dependency Injection**: Uses swift-dependencies for service injection
- **Multi-Process**: XPC services enable safe inspection of external processes

### Platform Requirements

- Swift 6.2, Xcode 15+
- Core: macOS 10.15+, iOS 13+
- Main App: macOS 14+, iOS 17+

## Key Source Locations

- Main app entry: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift`
- Coordinator/navigation: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift`
- Runtime engine: `Core/Sources/RuntimeViewerCore/RuntimeEngine.swift`
- ViewModels: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/`

## External Dependencies

Core reverse engineering powered by:
- [ClassDumpRuntime](https://github.com/MxIris-Reverse-Engineering/ClassDumpRuntime) - ObjC runtime introspection
- [MachOSwiftSection](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection) - Swift interface extraction
- [MachInjector](https://github.com/MxIris-Reverse-Engineering/MachInjector) - Code injection (requires SIP disabled)
