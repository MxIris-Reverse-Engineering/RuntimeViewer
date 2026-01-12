import AppKit
import SnapKit

open class AreaSegmentedControl: Control {
    private struct SegmentItem {
        var image: NSImage?
        var alternateImage: NSImage?
        var label: String = ""
        var width: CGFloat = 0
        var tag: Int = 0
        var toolTip: String?
        var isSelected: Bool = false
        var isEnabled: Bool = true
        var menu: NSMenu?
    }

    private var segments: [SegmentItem] = []
    private var segmentButtons: [AreaSegmentButton] = []

    private let topDivider = Divider()
    private let bottomDivider = Divider()

    open var trackingMode: NSSegmentedControl.SwitchTracking = .selectOne

    open var segmentCount: Int {
        get { segments.count }
        set { resizeSegments(to: newValue) }
    }

    @objc open var indexOfSelectedItem: Int { selectedSegment }
    
    open var selectedSegment: Int {
        get { segments.firstIndex(where: { $0.isSelected }) ?? -1 }
        set {
            guard isValidIndex(newValue) else { return }
            if trackingMode == .selectOne {
                for i in 0 ..< segmentCount {
                    setSelected(i == newValue, forSegment: i)
                }
            } else {
                setSelected(true, forSegment: newValue)
            }
        }
    }
    
    open override var intrinsicContentSize: NSSize {
        return .init(width: NSView.noIntrinsicMetric, height: 27)
    }

    open override func setup() {
        super.setup()
        hierarchy {
            topDivider
            bottomDivider
        }
    }

    open override func layout() {
        super.layout()

        for btn in segmentButtons {
            if btn.superview == nil { addSubview(btn) }
        }

        
        let height = bounds.height
        let width = bounds.width
        let buttonSpacing: CGFloat = 20
        let defaultButtonWidth = height

        topDivider.frame = .init(x: 0, y: 0, width: width, height: 1)
        
        let totalButtonWidth: CGFloat = segmentButtons.enumerated().reduce(0) { partialResult, item in
            let (index, _) = item
            let segWidth = self.width(forSegment: index)
            let currentWidth = segWidth > 0 ? segWidth : defaultButtonWidth
            let spacing = index == segmentButtons.count - 1 ? 0 : buttonSpacing
            return partialResult + currentWidth + spacing
        }

        let startX = (width - totalButtonWidth) / 2
        var currentX = startX

        for (index, button) in segmentButtons.enumerated() {
            let segWidth = self.width(forSegment: index)
            let actualWidth = segWidth > 0 ? segWidth : defaultButtonWidth
            button.frame = CGRect(x: currentX, y: 0, width: actualWidth, height: height - 2)
            currentX += actualWidth + buttonSpacing
        }
        
        bottomDivider.frame = .init(x: 0, y: height - 1, width: width, height: 1)
    }

    open func setLabel(_ label: String, forSegment segment: Int) {
        guard isValidIndex(segment) else { return }
        segments[segment].label = label
        segmentButtons[segment].title = label
    }

    open func label(forSegment segment: Int) -> String? {
        guard isValidIndex(segment) else { return nil }
        return segments[segment].label
    }

    open func setImage(_ image: NSImage?, forSegment segment: Int) {
        guard isValidIndex(segment) else { return }
        segments[segment].image = image
        segmentButtons[segment].image = image
    }

    open func image(forSegment segment: Int) -> NSImage? {
        guard isValidIndex(segment) else { return nil }
        return segments[segment].image
    }

    open func setAlternateImage(_ image: NSImage?, forSegment segment: Int) {
        guard isValidIndex(segment) else { return }
        segments[segment].alternateImage = image
        segmentButtons[segment].alternateImage = image
    }

    open func alternateImage(forSegment segment: Int) -> NSImage? {
        guard isValidIndex(segment) else { return nil }
        return segments[segment].alternateImage
    }

    open func setWidth(_ width: CGFloat, forSegment segment: Int) {
        guard isValidIndex(segment) else { return }
        segments[segment].width = width
        needsLayout = true
    }

    open func width(forSegment segment: Int) -> CGFloat {
        guard isValidIndex(segment) else { return 0 }
        return segments[segment].width
    }

    open func setEnabled(_ enabled: Bool, forSegment segment: Int) {
        guard isValidIndex(segment) else { return }
        segments[segment].isEnabled = enabled
        segmentButtons[segment].isEnabled = enabled
    }

    open func isEnabled(forSegment segment: Int) -> Bool {
        guard isValidIndex(segment) else { return false }
        return segments[segment].isEnabled
    }

    open func setSelected(_ selected: Bool, forSegment segment: Int) {
        guard isValidIndex(segment) else { return }
        segments[segment].isSelected = selected
        segmentButtons[segment].state = selected ? .on : .off

        if trackingMode == .selectOne, selected {
            for i in 0 ..< segmentCount where i != segment {
                segments[i].isSelected = false
                segmentButtons[i].state = .off
            }
        }
    }

    open func isSelected(forSegment segment: Int) -> Bool {
        guard isValidIndex(segment) else { return false }
        return segments[segment].isSelected
    }

    open func setTag(_ tag: Int, forSegment segment: Int) {
        guard isValidIndex(segment) else { return }
        segments[segment].tag = tag
    }

    open func tag(forSegment segment: Int) -> Int {
        guard isValidIndex(segment) else { return 0 }
        return segments[segment].tag
    }

    open func setToolTip(_ toolTip: String?, forSegment segment: Int) {
        guard isValidIndex(segment) else { return }
        segments[segment].toolTip = toolTip
        segmentButtons[segment].toolTip = toolTip
    }

    open func toolTip(forSegment segment: Int) -> String? {
        guard isValidIndex(segment) else { return nil }
        return segments[segment].toolTip
    }

    open func selectSegment(withTag tag: Int) -> Bool {
        if let index = segments.firstIndex(where: { $0.tag == tag }) {
            selectedSegment = index
            return true
        }
        return false
    }

    private func isValidIndex(_ index: Int) -> Bool {
        return index >= 0 && index < segments.count
    }

    private func resizeSegments(to newCount: Int) {
        let currentCount = segments.count
        if newCount > currentCount {
            for _ in currentCount ..< newCount {
                let newSegment = SegmentItem()
                segments.append(newSegment)
                let btn = AreaSegmentButton()
                btn.target = self
                btn.action = #selector(handleButtonClick(_:))
                segmentButtons.append(btn)
                addSubview(btn)
            }
        } else if newCount < currentCount {
            for _ in newCount ..< currentCount {
                segments.removeLast()
                let btn = segmentButtons.removeLast()
                btn.removeFromSuperview()
            }
        }
        needsLayout = true
    }

    @objc private func handleButtonClick(_ sender: AreaSegmentButton) {
        guard let index = segmentButtons.firstIndex(of: sender) else { return }
        let alreadySelected = isSelected(forSegment: index)

        switch trackingMode {
        case .selectOne:
            if !alreadySelected {
                selectedSegment = index
                sendAction(action, to: target)
            }
        case .selectAny:
            setSelected(!alreadySelected, forSegment: index)
            sendAction(action, to: target)
        case .momentary, .momentaryAccelerator:
            sendAction(action, to: target)
        @unknown default: break
        }
    }
}

final class AreaSegmentButton: Button {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.isBordered = false
        updateVisuals()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var state: NSControl.StateValue {
        didSet { updateVisuals() }
    }

    override var alternateImage: NSImage? {
        didSet { updateVisuals() }
    }

    private func updateVisuals() {
        image = state == .on ? alternateImage : image
        contentTintColor = state == .on ? .controlAccentColor : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateVisuals()
    }
}


import AppKit
import FrameworkToolbox

public protocol SegmentedControl: NSControl, FrameworkToolboxCompatible, FrameworkToolboxDynamicMemberLookup, TargetActionProvider {
    var segmentCount: Int { get set }
    var selectedSegment: Int { get set }
    var trackingMode: NSSegmentedControl.SwitchTracking { get set }
    var indexOfSelectedItem: Int { get }
    
    
    func setLabel(_ label: String, forSegment segment: Int)
    func label(forSegment segment: Int) -> String?
    
    func setImage(_ image: NSImage?, forSegment segment: Int)
    func image(forSegment segment: Int) -> NSImage?
    
    func setAlternateImage(_ image: NSImage?, forSegment segment: Int)
    func alternateImage(forSegment segment: Int) -> NSImage?
    
    func setWidth(_ width: CGFloat, forSegment segment: Int)
    func width(forSegment segment: Int) -> CGFloat
    
    func setEnabled(_ enabled: Bool, forSegment segment: Int)
    func isEnabled(forSegment segment: Int) -> Bool
    
    func setSelected(_ selected: Bool, forSegment segment: Int)
    func isSelected(forSegment segment: Int) -> Bool
    
    func setToolTip(_ toolTip: String?, forSegment segment: Int)
    func toolTip(forSegment segment: Int) -> String?
    
    func setTag(_ tag: Int, forSegment segment: Int)
    func tag(forSegment segment: Int) -> Int
    
    func selectSegment(withTag tag: Int) -> Bool
}

extension NSSegmentedControl: SegmentedControl {
    public func setAlternateImage(_ image: NSImage?, forSegment segment: Int) {}
    
    public func alternateImage(forSegment segment: Int) -> NSImage? { return nil }
    
    public func selectSegment(withTag tag: Int) -> Bool {
        for i in 0..<segmentCount {
            if self.tag(forSegment: i) == tag {
                self.selectedSegment = i
                return true
            }
        }
        return false
    }
}

extension AreaSegmentedControl: SegmentedControl {}
