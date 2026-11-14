import SwiftUI

#if os(macOS)
import AppKit

public struct RielaNoteSelectableTextEditor: NSViewRepresentable {
  @Binding private var text: String
  @Binding private var selectedRange: NSRange

  public init(text: Binding<String>, selectedRange: Binding<NSRange>) {
    _text = text
    _selectedRange = selectedRange
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, selectedRange: $selectedRange)
  }

  public func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    guard let textView = scrollView.documentView as? NSTextView else {
      return scrollView
    }
    textView.delegate = context.coordinator
    textView.string = text
    textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.drawsBackground = false
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.allowsUndo = true
    return scrollView
  }

  public func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? NSTextView else {
      return
    }
    if textView.string != text {
      textView.string = text
    }
    if textView.selectedRange() != selectedRange, selectedRange.location <= textView.string.utf16.count {
      textView.setSelectedRange(selectedRange)
      textView.scrollRangeToVisible(selectedRange)
    }
  }

  public final class Coordinator: NSObject, NSTextViewDelegate {
    private var text: Binding<String>
    private var selectedRange: Binding<NSRange>

    init(text: Binding<String>, selectedRange: Binding<NSRange>) {
      self.text = text
      self.selectedRange = selectedRange
    }

    public func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else {
        return
      }
      text.wrappedValue = textView.string
      selectedRange.wrappedValue = textView.selectedRange()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else {
        return
      }
      selectedRange.wrappedValue = textView.selectedRange()
    }
  }
}
#else
public struct RielaNoteSelectableTextEditor: View {
  @Binding private var text: String
  @Binding private var selectedRange: NSRange

  public init(text: Binding<String>, selectedRange: Binding<NSRange>) {
    _text = text
    _selectedRange = selectedRange
  }

  public var body: some View {
    TextEditor(text: $text)
      .onAppear {
        selectedRange = NSRange(location: 0, length: 0)
      }
  }
}
#endif
