//
//  ControlItem.swift
//  Ice
//

import Cocoa
import Combine

final class ControlItem: ObservableObject {
    /// A value representing the hiding state of a control item.
    enum State: RawRepresentable, Hashable, Codable {
        /// Status items in the control item's section are hidden.
        case hideItems(isExpanded: Bool)
        /// Status items in the control item's section are visible.
        case showItems

        var rawValue: Int {
            switch self {
            case .hideItems(isExpanded: false): return 0
            case .hideItems(isExpanded: true): return 1
            case .showItems: return 2
            }
        }

        init?(rawValue: Int) {
            switch rawValue {
            case 0: self = .hideItems(isExpanded: false)
            case 1: self = .hideItems(isExpanded: true)
            case 2: self = .showItems
            default: return nil
            }
        }
    }

    static let standardLength: CGFloat = 25

    static let expandedLength: CGFloat = 10_000

    /// The underlying status item associated with the control item.
    private let statusItem: NSStatusItem

    private var cancellables = Set<AnyCancellable>()

    /// The control item's autosave name.
    var autosaveName: String {
        statusItem.autosaveName
    }

    /// The status bar associated with the control item.
    weak var statusBar: StatusBar? {
        didSet {
            updateStatusItem()
        }
    }

    /// The control item's section in the status bar.
    var section: StatusBarSection? {
        statusBar?.section(for: self)
    }

    /// The position of the control item in the status bar.
    @Published private(set) var position: CGFloat?

    /// A Boolean value that indicates whether the control
    /// item is visible.
    ///
    /// This value corresponds to whether the item's section
    /// is enabled.
    @Published var isVisible: Bool

    /// The state of the control item.
    ///
    /// Setting this value marks the item as needing an update.
    @Published var state: State {
        didSet {
            updateStatusItem()
        }
    }

    init(
        autosaveName: String? = nil,
        position: CGFloat? = nil,
        isVisible: Bool = true,
        state: State? = nil
    ) {
        let autosaveName = autosaveName ?? UUID().uuidString
        if isVisible {
            // set the preferred position first; the status item won't
            // recognize when it's been set otherwise
            PreferredPosition[autosaveName] = position
            self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
            self.statusItem.autosaveName = autosaveName
            self.statusItem.isVisible = true
        } else {
            self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
            self.statusItem.autosaveName = autosaveName
            self.statusItem.isVisible = false
            // set the preferred position last; setting the status item
            // to invisible will have removed its preferred position if
            // it already had one stored stored in UserDefaults
            PreferredPosition[autosaveName] = position
        }
        self.position = position
        self.isVisible = isVisible
        self.state = state ?? .showItems
        configureStatusItem()
    }

    /// Sets the initial configuration for the status item.
    private func configureStatusItem() {
        defer {
            configureCancellables()
            updateStatusItem()
        }
        guard let button = statusItem.button else {
            return
        }
        button.target = self
        button.action = #selector(performAction)
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
    }

    private func configureCancellables() {
        // cancel and remove all current cancellables
        for cancellable in cancellables {
            cancellable.cancel()
        }
        cancellables.removeAll()

        if let window = statusItem.button?.window {
            window.publisher(for: \.frame)
                .combineLatest(window.publisher(for: \.screen))
                .compactMap { [weak statusItem] frame, screen in
                    // only publish when status item has a standard length and
                    // window is at least partially onscreen
                    guard
                        statusItem?.length == Self.standardLength,
                        let screenFrame = screen?.frame,
                        screenFrame.intersects(frame)
                    else {
                        return nil
                    }
                    // calculate position relative to trailing edge of screen
                    return screenFrame.maxX - frame.maxX
                }
                .removeDuplicates()
                .sink { [weak self] position in
                    self?.position = position
                }
                .store(in: &cancellables)
        }

        statusItem.publisher(for: \.isVisible)
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.isVisible = isVisible
            }
            .store(in: &cancellables)

        $isVisible
            .removeDuplicates()
            .sink { [weak self] isVisible in
                guard let self else {
                    return
                }
                let autosaveName = autosaveName
                let cached = PreferredPosition[autosaveName]
                defer {
                    PreferredPosition[autosaveName] = cached
                }
                statusItem.isVisible = isVisible
                statusBar?.needsSave = true
            }
            .store(in: &cancellables)

        objectWillChange
            .sink { [weak statusBar] in
                statusBar?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Updates the control item's status item to match its current state.
    func updateStatusItem() {
        func updateLength(section: StatusBarSection) {
            if section.name == .alwaysVisible {
                // item for always-visible section should never be expanded
                statusItem.length = Self.standardLength
                return
            }
            switch state {
            case .showItems, .hideItems(isExpanded: false):
                statusItem.length = Self.standardLength
            case .hideItems(isExpanded: true):
                statusItem.length = Self.expandedLength
            }
        }

        func updateButton(section: StatusBarSection) {
            guard let button = statusItem.button else {
                return
            }
            if state == .hideItems(isExpanded: true) {
                // prevent the cell from highlighting while expanded
                button.cell?.isEnabled = false
                // cell still sometimes briefly flashes during expansion;
                // manually unhighlighting seems to mitigate it
                button.isHighlighted = false
                button.image = nil
                return
            }
            // enable the cell, as it may have been previously disabled
            button.cell?.isEnabled = true
            // set the image based on section and state
            switch section.name {
            case .hidden:
                button.image = Images.largeChevron
            case .alwaysHidden:
                button.image = Images.smallChevron
            case .alwaysVisible:
                switch state {
                case .hideItems:
                    button.image = Images.circleFilled
                case .showItems:
                    button.image = Images.circleStroked
                }
            default:
                break
            }
        }

        guard let section else {
            return
        }

        updateLength(section: section)
        updateButton(section: section)

        statusBar?.needsSave = true
    }

    @objc private func performAction() {
        guard
            let statusBar,
            let event = NSApp.currentEvent
        else {
            return
        }
        switch event.type {
        case .leftMouseDown where NSEvent.modifierFlags == .option:
            statusBar.showSection(withName: .alwaysHidden)
        case .leftMouseDown:
            guard let section else {
                return
            }
            statusBar.toggle(section: section)
        case .rightMouseUp:
            statusItem.showMenu(createMenu(with: statusBar))
        default:
            break
        }
    }

    /// Creates and returns a menu to show when the control item is
    /// right-clicked.
    private func createMenu(with statusBar: StatusBar) -> NSMenu {
        let menu = NSMenu(title: Constants.appName)

        // add menu items to toggle the hidden and always-hidden sections,
        // assuming each section is enabled
        let sectionNames: [StatusBarSection.Name] = [.hidden, .alwaysHidden]
        for name in sectionNames {
            guard
                let section = statusBar.section(withName: name),
                statusBar.isSectionEnabled(section)
            else {
                continue
            }
            let item = NSMenuItem(
                title: (statusBar.isSectionHidden(section) ? "Show" : "Hide") + " \"\(name.rawValue)\" Section",
                action: #selector(runKeyCommandHandlers),
                keyEquivalent: ""
            )
            item.target = self
            if let hotkey = section.hotkey {
                item.keyEquivalent = hotkey.key.keyEquivalent
                item.keyEquivalentModifierMask = hotkey.modifiers.nsEventFlags
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(Constants.appName)",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        return menu
    }

    /// Action for a menu item in the control item's menu to perform.
    @objc private func runKeyCommandHandlers(for menuItem: NSMenuItem) {
        guard
            let statusBar,
            let section
        else {
            return
        }
        statusBar.toggle(section: section)
    }

    deinit {
        // removing the status item has the unwanted side effect of deleting
        // the preferred position; cache and restore after removing
        let autosaveName = autosaveName
        let cached = PreferredPosition[autosaveName]
        defer {
            PreferredPosition[autosaveName] = cached
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

// MARK: ControlItem: Codable
extension ControlItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case autosaveName
        case position
        case state
        case isVisible
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            autosaveName: container.decode(String.self, forKey: .autosaveName),
            position: container.decode(CGFloat.self, forKey: .position),
            isVisible: container.decode(Bool.self, forKey: .isVisible),
            state: container.decode(State.self, forKey: .state)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autosaveName, forKey: .autosaveName)
        try container.encode(position, forKey: .position)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(state, forKey: .state)
    }
}

// MARK: ControlItem: Equatable
extension ControlItem: Equatable {
    static func == (lhs: ControlItem, rhs: ControlItem) -> Bool {
        lhs.autosaveName == rhs.autosaveName &&
        lhs.position == rhs.position &&
        lhs.isVisible == rhs.isVisible &&
        lhs.state == rhs.state
    }
}

// MARK: ControlItem: Hashable
extension ControlItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(autosaveName)
        hasher.combine(position)
        hasher.combine(isVisible)
        hasher.combine(state)
    }
}

// MARK: - PreferredPosition
extension ControlItem {
    /// A proxy getter and setter for a control item's preferred position.
    enum PreferredPosition {
        private static func key(for autosaveName: String) -> String {
            return "NSStatusItem Preferred Position \(autosaveName)"
        }

        /// Accesses the preferred position associated with the specified autosave name.
        static subscript(autosaveName: String) -> CGFloat? {
            get {
                // use object(forKey:) because double(forKey:) returns 0 if no value
                // is stored; we need to differentiate between "a stored value of 0"
                // and "no stored value"
                UserDefaults.standard.object(forKey: key(for: autosaveName)) as? CGFloat
            }
            set {
                UserDefaults.standard.set(newValue, forKey: key(for: autosaveName))
            }
        }
    }
}

// MARK: - Images
extension ControlItem {
    /// Namespace for control item images.
    enum Images {
        static let circleFilled: NSImage = {
            let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { bounds in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: bounds).fill()
                return true
            }
            image.isTemplate = true
            return image
        }()

        static let circleStroked: NSImage = {
            let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { bounds in
                let lineWidth: CGFloat = 1.5
                let path = NSBezierPath(ovalIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
                path.lineWidth = lineWidth
                NSColor.black.setStroke()
                path.stroke()
                return true
            }
            image.isTemplate = true
            return image
        }()

        static let (largeChevron, smallChevron): (NSImage, NSImage) = {
            func chevron(size: NSSize, lineWidth: CGFloat = 2) -> NSImage {
                let image = NSImage(size: size, flipped: false) { bounds in
                    let insetBounds = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.maxY))
                    path.line(to: NSPoint(x: (insetBounds.minX + insetBounds.midX) / 2, y: insetBounds.midY))
                    path.line(to: NSPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.minY))
                    path.lineWidth = lineWidth
                    path.lineCapStyle = .butt
                    NSColor.black.setStroke()
                    path.stroke()
                    return true
                }
                image.isTemplate = true
                return image
            }
            let largeChevron = chevron(size: NSSize(width: 12, height: 12))
            let smallChevron = chevron(size: NSSize(width: 7, height: 7))
            return (largeChevron, smallChevron)
        }()
    }
}