import SwiftUI

struct RielaNoteQuickCreateButton: View {
  var canCreateInNotebook: Bool
  var onCreateMemo: () -> Void
  var onCreateInNotebook: () -> Void
  @State private var isExpanded = false

  var body: some View {
    HStack(spacing: 8) {
      if isExpanded {
        Button {
          onCreateMemo()
        } label: {
          Label("New memo", systemImage: "square.and.pencil")
        }
        .buttonStyle(.borderedProminent)
        if canCreateInNotebook {
          Button {
            onCreateInNotebook()
          } label: {
            Label("New note", systemImage: "doc.badge.plus")
          }
          .buttonStyle(.bordered)
        }
      }
      Button {
        onCreateMemo()
      } label: {
        Image(systemName: "plus")
          .font(.title3.weight(.semibold))
          .frame(width: 44, height: 44)
      }
      .buttonStyle(.borderedProminent)
      .clipShape(Circle())
      .accessibilityLabel("New note")
      .help("New memo")
      .contextMenu {
        Button("New memo", action: onCreateMemo)
        if canCreateInNotebook {
          Button("New note in notebook", action: onCreateInNotebook)
        }
      }
    }
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.16)) {
        isExpanded = hovering
      }
    }
  }
}
