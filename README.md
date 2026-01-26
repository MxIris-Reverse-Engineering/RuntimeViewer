<p align="center">
  <img width="30%" src="Resources/AppIcon.png">
</p>

<h1 align="center">Runtime Viewer</h1>

<p align="center">
  A modern alternative to RuntimeBrowser with enhanced UI and extended functionality
</p>

## Powered By

| Language | Library |
|----------|---------|
| Objective-C | [MachOObjCSection](https://github.com/p-x9/MachOObjCSection) |
| Swift | [MachOSwiftSection](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection) |

## Highlights

- **Swift Interface Support** – View Swift interfaces alongside Objective-C headers
- **Xcode-Style Syntax Highlighting** – Full AppKit/UIKit text view with type-defined jumps and highlighting identical to Xcode
- **Framework Support** – Browse `macOS` frameworks and `iOSSupport` frameworks
- **Easy Export** – Export header or interface files with one click
- **Custom Framework Loading** – Load and inspect custom macOS frameworks
- **Code Injection** – Inject code into running processes (WIP: arm64e support, requires SIP disabled)
- **Multi-Device Support** *(WIP)* – Connect to iOS, watchOS, tvOS, and visionOS devices via Bonjour (requires RuntimeViewerMobileServer)

> [!NOTE]
> Some features marked as *WIP* are only available in beta versions. If you need these features, please download from [Pre-release](../../releases).

## Getting Started

### XPC Helper Installation

On first launch, you need to install the XPC helper for inter-process communication. Click the tool icon in the toolbar to install it.

### Troubleshooting

If Catalyst or code-injected applications don't appear in the directory list, try restarting the application.

## Screenshots

![Screenshot 1](./Resources/Screenshot-001.png)
![Screenshot 2](./Resources/Screenshot-002.png)
![Screenshot 3](./Resources/Screenshot-003.png)
