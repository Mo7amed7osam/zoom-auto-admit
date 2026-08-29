import AppKit

/// Shared visual language for the app's windows.
///
/// The forms used to be flat stacks of label-and-field pairs on a bare window
/// background, which reads as a dialog from a decade ago. Grouping related
/// controls into inset cards with hairline separators is what the system's own
/// settings surfaces do, and it is most of the difference between "a utility"
/// and "a tool someone designed".
enum DesignKit {
    enum Metrics {
        static let windowMargin: CGFloat = 20
        static let cardCornerRadius: CGFloat = 10
        static let cardInset: CGFloat = 14
        static let rowSpacing: CGFloat = 12
        static let sectionSpacing: CGFloat = 22
        static let labelColumnWidth: CGFloat = 148
    }

    // MARK: Type

    /// Sentence case, not upper. Current macOS settings surfaces dropped
    /// all-caps headers, and upper-casing here also rewrote the very strings
    /// the rest of the app looks itself up by.
    static func sectionHeader(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    static func rowLabel(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.alignment = .right
        field.textColor = .labelColor
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    static func caption(_ text: String, width: CGFloat = 420) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = width
        return field
    }

    static func errorLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.textColor = .systemRed
        field.isHidden = true
        return field
    }

    // MARK: Structure

    /// A titled group of rows, drawn as an inset card.
    static func section(_ title: String?, rows: [NSView]) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = Metrics.cardCornerRadius
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        // Hairlines between rows, never above the first or below the last.
        var content: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { content.append(separator()) }
            content.append(row)
        }

        let stack = NSStackView(views: content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.rowSpacing
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.cardInset,
            left: Metrics.cardInset,
            bottom: Metrics.cardInset,
            right: Metrics.cardInset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        guard let title else { return card }

        let group = NSStackView(views: [sectionHeader(title), card])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 7
        return group
    }

    static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// A label-and-control row with a fixed label column, so every row in every
    /// card lines up on the same axis.
    static func row(
        _ title: String,
        _ control: NSView,
        suffix: String? = nil,
        error: NSTextField? = nil,
        hint: String? = nil
    ) -> NSView {
        let label = rowLabel(title)
        label.widthAnchor.constraint(equalToConstant: Metrics.labelColumnWidth).isActive = true

        var controls: [NSView] = [label, control]
        if let suffix {
            let suffixLabel = NSTextField(labelWithString: suffix)
            suffixLabel.textColor = .secondaryLabelColor
            suffixLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
            controls.append(suffixLabel)
        }

        let line = NSStackView(views: controls)
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 10

        var stacked: [NSView] = [line]
        for extra in [error, hint.map { caption($0, width: 360) }].compactMap({ $0 }) {
            let spacer = NSView()
            spacer.widthAnchor.constraint(equalToConstant: Metrics.labelColumnWidth + 10).isActive = true
            let indented = NSStackView(views: [spacer, extra])
            indented.orientation = .horizontal
            indented.spacing = 0
            indented.alignment = .top
            stacked.append(indented)
        }

        guard stacked.count > 1 else { return line }

        let stack = NSStackView(views: stacked)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    /// A row whose content spans the full width, for checkboxes and captions.
    static func fullWidthRow(_ view: NSView, indented: Bool = true) -> NSView {
        guard indented else { return view }
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: Metrics.labelColumnWidth + 10).isActive = true
        let stack = NSStackView(views: [spacer, view])
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        return stack
    }

    static func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        return stack
    }

    // MARK: Controls

    static func primaryButton(title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.controlSize = .large
        return button
    }

    static func button(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// A large number over a caption, for a summary strip.
    static func statTile(value: String, caption: String, tint: NSColor) -> NSView {
        let number = NSTextField(labelWithString: value)
        number.font = .systemFont(ofSize: 26, weight: .medium)
        number.textColor = tint
        number.alignment = .center

        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let stack = NSStackView(views: [number, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = Metrics.cardCornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 92)
        ])
        return container
    }
}
