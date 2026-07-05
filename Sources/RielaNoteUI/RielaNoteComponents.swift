import RielaNote
import SwiftUI

struct RielaNoteTagChipRow: View {
  var tags: [TagAssignment]

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(tags, id: \.tag.tagId) { assignment in
        RielaNoteTagChip(label: assignment.tag.name, provenance: assignment.provenance)
      }
    }
  }
}

struct RielaNoteTagChip: View {
  var label: String
  var provenance: NoteProvenance

  var body: some View {
    Label(label, systemImage: systemImage)
      .font(.caption)
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .foregroundStyle(foreground)
      .background(background, in: Capsule())
  }

  private var systemImage: String {
    switch provenance {
    case .human:
      "person"
    case .ai:
      "sparkles"
    case .system:
      "lock"
    }
  }

  private var foreground: Color {
    switch provenance {
    case .human:
      .blue
    case .ai:
      .green
    case .system:
      .secondary
    }
  }

  private var background: Color {
    switch provenance {
    case .human:
      .blue.opacity(0.12)
    case .ai:
      .green.opacity(0.14)
    case .system:
      .secondary.opacity(0.12)
    }
  }
}

struct RielaNoteMarkdownText: View {
  var markdown: String

  var body: some View {
    if let attributed = try? AttributedString(markdown: markdown) {
      Text(attributed)
        .textSelection(.enabled)
    } else {
      Text(markdown)
        .textSelection(.enabled)
    }
  }
}

struct RielaNoteSourceImageView: View {
  var decodedImage: RielaNoteDecodedSourceImage?
  var resolvedFile: RielaNoteResolvedFile?
  var attachment: NoteFileAttachment?
  var isLoading = false
  var zoomScale: Double = 1

  var body: some View {
    Group {
      if let decodedImage {
        Image(decorative: decodedImage.cgImage, scale: 1, orientation: .up)
          .resizable()
          .scaledToFit()
          .scaleEffect(zoomScale)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if isLoading {
        VStack(spacing: 10) {
          ProgressView()
          Text("Loading source image")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
      } else if let file = resolvedFile?.file ?? attachment?.file {
        VStack(spacing: 8) {
          Image(systemName: "photo")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text(file.originalFilename ?? file.fileId)
            .font(.headline)
          Text("\(file.byteSize) bytes")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
      } else {
        ContentUnavailableView("No source image", systemImage: "photo")
      }
    }
  }
}

struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Void
  ) -> CGSize {
    let rows = arrangeSubviews(proposal: proposal, subviews: subviews)
    return CGSize(
      width: proposal.width ?? rows.map(\.width).max() ?? 0,
      height: rows.last.map { $0.y + $0.height } ?? 0
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Void
  ) {
    for row in arrangeSubviews(proposal: proposal, subviews: subviews) {
      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
          proposal: ProposedViewSize(item.size)
        )
      }
    }
  }

  private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> [FlowRow] {
    let maxWidth = proposal.width ?? .greatestFiniteMagnitude
    var rows: [FlowRow] = []
    var current = FlowRow(y: 0)
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if current.width > 0, current.width + spacing + size.width > maxWidth {
        rows.append(current)
        current = FlowRow(y: current.y + current.height + spacing)
      }
      let x = current.width == 0 ? 0 : current.width + spacing
      current.items.append(FlowItem(index: index, x: x, size: size))
      current.width = x + size.width
      current.height = max(current.height, size.height)
    }
    rows.append(current)
    return rows
  }
}

private struct FlowRow {
  var y: CGFloat
  var width: CGFloat = 0
  var height: CGFloat = 0
  var items: [FlowItem] = []
}

private struct FlowItem {
  var index: Int
  var x: CGFloat
  var size: CGSize
}
