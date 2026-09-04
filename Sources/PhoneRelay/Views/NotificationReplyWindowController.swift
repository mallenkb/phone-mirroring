import AppKit

/// A retained window keeps an unsent draft through close/reopen without writing
/// message contents to preferences or the Mac clipboard.
@MainActor
final class NotificationReplyWindowController: NSWindowController, NSTextViewDelegate {
    private let editor = NotificationReplyTextView()
    private let status = NSTextField(wrappingLabelWithString: "Enter to send · Shift-Enter for a new line")
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private var sending = false
    private var submissionAttempted = false
    var sendReply: ((String, @escaping (NotificationReplyService.Outcome) -> Void) -> Void)?
    var openConversation: (() -> Void)?

    init(appName: String, sender: String, message: String, draft: String = "") {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Reply · \(appName)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 300)
        super.init(window: window)

        let heading = NSTextField(labelWithString: sender.isEmpty ? appName : sender)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let context = NSTextField(wrappingLabelWithString: message)
        context.textColor = .secondaryLabelColor
        context.maximumNumberOfLines = 4
        context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.string = draft
        editor.setAccessibilityLabel("Reply message")
        editor.delegate = self
        editor.onSend = { [weak self] in self?.send() }
        editor.onDismiss = { [weak self] in self?.close() }

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        editor.frame = NSRect(x: 0, y: 0, width: 410, height: 130)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityElement(true)
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.bezelStyle = .rounded
        let open = NSButton(title: "Open on Phone", target: self, action: #selector(openPhone))
        open.bezelStyle = .rounded
        let buttons = NSStackView(views: [open, NSView(), sendButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [heading, context, scroll, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            context.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateSendButton()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
    }

    func textDidChange(_ notification: Notification) { updateSendButton() }

    private func updateSendButton() {
        sendButton.isEnabled = !sending && !submissionAttempted
            && !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func openPhone() { openConversation?() }

    @objc private func send() {
        guard sendButton.isEnabled, let sendReply else { return }
        let draft = editor.string
        sending = true
        editor.isEditable = false
        status.stringValue = "Sending through your phone…"
        updateSendButton()
        sendReply(draft) { [weak self] outcome in
            guard let self else { return }
            self.sending = false
            self.editor.isEditable = true
            self.status.stringValue = outcome.message
            // An ambiguous send must never be retried from another Enter press.
            // Keep the draft so the user can check the conversation first.
            self.submissionAttempted = outcome.didAttemptSubmission
            if outcome == .submitted { self.editor.string = "" }
            self.updateSendButton()
        }
    }
}

final class NotificationReplyTextView: NSTextView {
    var onSend: (() -> Void)?
    var onDismiss: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Let the input method finish composing before interpreting Return.
        if !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                if isEditable { insertNewlineIgnoringFieldEditor(self) }
            } else {
                onSend?()
            }
            return
        }
        if !hasMarkedText(), event.keyCode == 53 { onDismiss?(); return }
        if !hasMarkedText(), event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        super.keyDown(with: event)
    }
}
