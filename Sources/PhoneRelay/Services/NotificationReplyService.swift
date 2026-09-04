import Foundation

/// Runs only on the notification interaction queue. No coordinate guesses or
/// automatic retries after submitting text to Android.
enum NotificationReplyService {
    enum Outcome: Equatable {
        case submitted, unconfirmed, failed(String)
        var didAttemptSubmission: Bool {
            switch self { case .submitted, .unconfirmed: return true; case .failed: return false }
        }
        var message: String {
            switch self {
            case .submitted: return "Reply submitted on your phone."
            case .unconfirmed: return "Send was attempted. Check the conversation before sending again. Your draft is kept here."
            case .failed(let reason): return reason + " Your draft is kept here."
            }
        }
    }

    final class Node {
        let attributes: [String: String]
        var children: [Node] = []
        init(_ attributes: [String: String]) { self.attributes = attributes }
        var all: [Node] { [self] + children.flatMap(\.all) }
        var text: String { attributes["text"] ?? "" }
        func hasID(_ suffix: String) -> Bool { attributes["resource-id"]?.hasSuffix("/" + suffix) == true }
        var enabled: Bool { attributes["enabled"] == "true" }
        var center: (Int, Int)? {
            let numbers = (attributes["bounds"] ?? "").split { !$0.isNumber }.compactMap { Int($0) }
            guard numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1] else { return nil }
            return ((numbers[0] + numbers[2]) / 2, (numbers[1] + numbers[3]) / 2)
        }
    }

    private final class Hierarchy: NSObject, XMLParserDelegate {
        var roots: [Node] = []
        var stack: [Node] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            guard elementName == "node" else { return }
            let node = Node(attributes)
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if elementName == "node", !stack.isEmpty { stack.removeLast() }
        }
    }

    static func parseHierarchy(_ output: String) -> [Node]? {
        guard output.utf8.count < 2_000_000,
              let start = output.range(of: "<?xml"), let end = output.range(of: "</hierarchy>") else { return nil }
        let parser = XMLParser(data: Data(output[start.lowerBound..<end.upperBound].utf8))
        let delegate = Hierarchy()
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.roots.flatMap(\.all)
    }

    static func send(serial: String, package: String, key: String, title: String, text: String,
                     reply: String, paste: (String) -> Bool) -> Outcome {
        func run(_ args: [String]) -> Tooling.RunResult {
            Tooling.runResult("adb", arguments: ["-s", serial] + args, timeout: 4)
        }
        func hierarchy() -> [Node]? {
            let result = run(["exec-out", "uiautomator", "dump", "/dev/tty"])
            return result.succeeded ? parseHierarchy(result.output) : nil
        }
        func card(_ nodes: [Node]) -> Node? {
            let matches = nodes.filter { node in
                guard node.hasID("expandableNotificationRow"),
                      node.attributes["package"] == "com.android.systemui",
                      !node.children.flatMap(\.all).contains(where: { $0.hasID("expandableNotificationRow") }) else { return false }
                let descendants = node.all
                return descendants.contains { $0.hasID("app_name_text") && $0.text == NotificationForwarder.appLabel(for: package) }
                    && descendants.contains { $0.hasID("title") && $0.text == title }
                    && descendants.contains { !$0.text.isEmpty && $0.text == text }
            }
            return matches.count == 1 ? matches[0] : nil
        }
        func tap(_ node: Node) -> Bool {
            guard node.enabled, let (x, y) = node.center else { return false }
            return run(["shell", "input", "tap", String(x), String(y)]).succeeded
        }
        func editor(_ card: Node) -> Node? {
            let matches = card.all.filter { $0.hasID("remote_input_text") && $0.enabled && $0.attributes["focused"] == "true" }
            return matches.count == 1 ? matches[0] : nil
        }
        guard !title.isEmpty, !text.isEmpty, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("This notification does not expose enough information for a safe reply. Use Open on Phone.")
        }
        guard let dump = NotificationForwarder.fetchDump(serial: serial),
              NotificationForwarder.parse(dump).contains(where: { $0.key == key && $0.pkg == package && $0.title == title && $0.text == text }) else {
            return .failed("The original notification changed or is no longer available. Use Open on Phone.")
        }
        guard NotificationTapService.wakeUnlockAndExpandShade(serial: serial, notificationKey: key),
              let nodes = hierarchy(), var original = card(nodes) else {
            return .failed("Could not identify this notification on the unlocked phone. Use Open on Phone.")
        }
        func replyActions(_ node: Node) -> [Node] {
            node.all.filter { $0.hasID("action0") && $0.enabled && $0.text.localizedCaseInsensitiveCompare("Reply") == .orderedSame }
        }
        if replyActions(original).isEmpty {
            let expand = original.all.filter { $0.hasID("expand_button") && $0.enabled }
            if expand.count == 1, tap(expand[0]), let expanded = hierarchy(), let refreshed = card(expanded) {
                original = refreshed
            }
        }
        let actions = replyActions(original)
        guard actions.count == 1, tap(actions[0]), let expanded = hierarchy(), let target = card(expanded),
              let field = editor(target), field.text.isEmpty else {
            return .failed("The phone did not expose an empty reply field. Existing phone drafts are not overwritten.")
        }
        guard paste(reply) else { return .failed("Open the phone mirror and try again.") }
        guard let populated = hierarchy(), let ready = card(populated), editor(ready)?.text == reply else {
            return .failed("Could not verify the complete reply in the phone's editor. Check Open on Phone before retrying.")
        }
        let sends = ready.all.filter { $0.hasID("remote_input_send") && $0.enabled }
        guard sends.count == 1 else { return .failed("The phone's Send button is unavailable.") }
        // A failed tool result may still follow a delivered tap. Never retry it.
        guard tap(sends[0]) else { return .unconfirmed }
        guard let after = hierarchy(), let remaining = card(after),
              remaining.all.contains(where: { $0.hasID("remote_input_text") && $0.text.isEmpty }) else { return .unconfirmed }
        return .submitted
    }
}
