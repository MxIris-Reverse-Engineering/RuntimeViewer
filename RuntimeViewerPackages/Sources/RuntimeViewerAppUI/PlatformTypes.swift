// The platform's image, colour and font types under one name, so that the models this module makes
// read the same on AppKit and UIKit. UIFoundation and SFSymbols declare the same aliases for the same
// types; a file that sees more than one of them still compiles, because all of them name one type.
#if os(macOS)
import AppKit

public typealias NSUIImage = NSImage
public typealias NSUIColor = NSColor
public typealias NSUIFont = NSFont
#else
import UIKit

public typealias NSUIImage = UIImage
public typealias NSUIColor = UIColor
public typealias NSUIFont = UIFont
#endif
