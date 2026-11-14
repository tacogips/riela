#if os(macOS)
import AppKit

enum RielaAppEnvironmentValueFormatter {
  static func text(values: [RielaAppConfiguredEnvironmentValue], revealsValues: Bool) -> String {
    guard !values.isEmpty else {
      return "No .env or inline environment values are configured."
    }
    return values
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      .map { value in
        let renderedValue = revealsValues ? value.value : mask(value.value)
        return "\(value.name)=\(renderedValue) (\(value.source))"
      }
      .joined(separator: "\n")
  }

  static func mask(_ value: String) -> String {
    String(repeating: "•", count: min(max(value.count, 1), 8))
  }
}

@MainActor
final class EnvironmentRevealToggleTarget: NSObject {
  private let textView: NSTextView
  private let values: [RielaAppConfiguredEnvironmentValue]
  private weak var checkbox: NSButton?

  init(textView: NSTextView, values: [RielaAppConfiguredEnvironmentValue], checkbox: NSButton) {
    self.textView = textView
    self.values = values
    self.checkbox = checkbox
  }

  @objc func toggle() {
    textView.string = RielaAppEnvironmentValueFormatter.text(
      values: values,
      revealsValues: checkbox?.state == .on
    )
  }
}
#endif
