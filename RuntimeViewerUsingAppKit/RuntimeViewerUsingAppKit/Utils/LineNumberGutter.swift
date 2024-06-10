//
// LineNumberGutter.swift
// LineNumberTextView
// https://github.com/raphaelhanneken/line-number-text-view
//
// The MIT License (MIT)
//
// Copyright (c) 2015 Raphael Hanneken
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Cocoa

/// Defines the width of the gutter view.
private let GUTTER_WIDTH: CGFloat = 40.0


/// Adds line numbers to a NSTextField.
class LineNumberGutter: NSRulerView {

    /// Holds the background color.
    @Invalidating(.display)
    var backgroundColor: NSColor = .controlBackgroundColor

    /// Holds the text color.
    @Invalidating(.display)
    var foregroundColor: NSColor = .secondaryLabelColor

    @Invalidating(.display)
    var font: NSFont = NSFont(descriptor: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular).fontDescriptor.withSymbolicTraits(.condensed), size: 0) ?? NSFont.monospacedSystemFont(ofSize: 0, weight: .regular)
    
    ///  Initializes a LineNumberGutter with the given attributes.
    ///
    ///  - parameter textView:        NSTextView to attach the LineNumberGutter to.
    ///  - parameter foregroundColor: Defines the foreground color.
    ///  - parameter backgroundColor: Defines the background color.
    ///
    ///  - returns: An initialized LineNumberGutter object.
    init(withTextView textView: NSTextView, foregroundColor: NSColor, backgroundColor: NSColor) {
        // Set the color preferences.
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor

        // Make sure everything's set up properly before initializing properties.
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)

        // Set the rulers clientView to the supplied textview.
        self.clientView = textView
        // Define the ruler's width.
        self.ruleThickness = GUTTER_WIDTH
    }

    ///  Initializes a default LineNumberGutter, attached to the given textView.
    ///  Default foreground color: hsla(0, 0, 0, 0.55);
    ///  Default background color: hsla(0, 0, 0.95, 1);
    ///
    ///  - parameter textView: NSTextView to attach the LineNumberGutter to.
    ///
    ///  - returns: An initialized LineNumberGutter object.
    convenience init(withTextView textView: NSTextView) {
        let fg = NSColor(calibratedHue: 0, saturation: 0, brightness: 0, alpha: 1)
        let bg = NSColor(calibratedHue: 0, saturation: 0, brightness: 0, alpha: 1)
        // Call the designated initializer.
        self.init(withTextView: textView, foregroundColor: fg, backgroundColor: bg)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    ///  Draws the line numbers.
    ///
    ///  - parameter rect: NSRect to draw the gutter view in.
    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Set the current background color...
        self.backgroundColor.set()
        // ...and fill the given rect.
        bounds.fill()

        // Unwrap the clientView, the layoutManager and the textContainer, since we'll
        // them sooner or later.
        guard let textView      = self.clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return
        }

        let content = textView.string

        // Get the range of the currently visible glyphs.
        let visibleGlyphsRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)

        // Check how many lines are out of the current bounding rect.
        var lineNumber: Int = 1
        do {
            // Define a regular expression to find line breaks.
            let newlineRegex = try NSRegularExpression(pattern: "\n", options: [])
            // Check how many lines are out of view; From the glyph at index 0
            // to the first glyph in the visible rect.
            lineNumber += newlineRegex.numberOfMatches(in: content, options: [], range: NSMakeRange(0, visibleGlyphsRange.location))
        } catch {
            return
        }

        // Get the index of the first glyph in the visible rect, as starting point...
        var firstGlyphOfLineIndex = visibleGlyphsRange.location

        // ...then loop through all visible glyphs, line by line.
        while firstGlyphOfLineIndex < NSMaxRange(visibleGlyphsRange) {
            // Get the character range of the line we're currently in.
            let charRangeOfLine  = (content as NSString).lineRange(for: NSRange(location: layoutManager.characterIndexForGlyph(at: firstGlyphOfLineIndex), length: 0))
            // Get the glyph range of the line we're currently in.
            let glyphRangeOfLine = layoutManager.glyphRange(forCharacterRange: charRangeOfLine, actualCharacterRange: nil)

            var firstGlyphOfRowIndex = firstGlyphOfLineIndex
            var lineWrapCount        = 0

            // Loop through all rows (soft wraps) of the current line.
            while firstGlyphOfRowIndex < NSMaxRange(glyphRangeOfLine) {
                // The effective range of glyphs within the current line.
                var effectiveRange = NSRange(location: 0, length: 0)
                // Get the rect for the current line fragment.
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: firstGlyphOfRowIndex, effectiveRange: &effectiveRange, withoutAdditionalLayout: true)

                // Draw the current line number;
                // When lineWrapCount > 0 the current line spans multiple rows.
                if lineWrapCount == 0 {
                    self.drawLineNumber(num: lineNumber, atYPosition: lineRect.minY)
                } else {
                    break
                }

                // Move to the next row.
                firstGlyphOfRowIndex = NSMaxRange(effectiveRange)
                lineWrapCount+=1
            }

            // Move to the next line.
            firstGlyphOfLineIndex = NSMaxRange(glyphRangeOfLine)
            lineNumber+=1
        }

        // Draw another line number for the extra line fragment.
        if let _ = layoutManager.extraLineFragmentTextContainer {
            self.drawLineNumber(num: lineNumber, atYPosition: layoutManager.extraLineFragmentRect.minY)
        }
    }


    func drawLineNumber(num: Int, atYPosition yPos: CGFloat) {
        // Unwrap the text view.
        guard let textView = self.clientView as? NSTextView else {
            return
        }
        // Define attributes for the attributed string.
        let attrs = [NSAttributedString.Key.font: font, NSAttributedString.Key.foregroundColor: self.foregroundColor]
        // Define the attributed string.
        let attributedString = NSAttributedString(string: "\(num)", attributes: attrs)
        // Get the NSZeroPoint from the text view.
        let relativePoint    = self.convert(NSZeroPoint, from: textView)
        // Calculate the x position, within the gutter.
        let xPosition        = GUTTER_WIDTH - (attributedString.size().width + 5)
        // Draw the attributed string to the calculated point.
        attributedString.draw(at: NSPoint(x: xPosition, y: relativePoint.y + yPos))
    }
}
