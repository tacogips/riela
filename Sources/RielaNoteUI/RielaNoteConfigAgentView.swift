import SwiftUI

public struct RielaNoteConfigAgentView: View {
  @ObservedObject private var viewModel: RielaNoteConfigAgentViewModel

  public init(viewModel: RielaNoteConfigAgentViewModel) {
    self.viewModel = viewModel
  }

  public var body: some View {
    VStack(spacing: 0) {
      workflowRootBar
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(viewModel.proposals) { proposal in
            RielaNoteConfigProposalView(proposal: proposal) {
              Task {
                await viewModel.applyProposal(id: proposal.id)
              }
            }
          }
        }
        .padding()
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      Divider()
      composer
    }
    .navigationTitle("Config")
  }

  private var workflowRootBar: some View {
    HStack(spacing: 10) {
      Label("Workflows", systemImage: "folder")
        .foregroundStyle(.secondary)
      TextField("Workflow root", text: $viewModel.workflowRoot)
        .textFieldStyle(.roundedBorder)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField("Ask Config Agent", text: $viewModel.draftMessage, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...5)
      Button {
        Task {
          await viewModel.submitDraft()
        }
      } label: {
        Label("Send", systemImage: "paperplane.fill")
      }
      .buttonStyle(.borderedProminent)
      .disabled(!viewModel.canSubmit)
    }
    .padding()
  }
}

struct RielaNoteConfigProposalView: View {
  var proposal: RielaNoteConfigAgentProposal
  var onApply: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      RielaNoteMarkdownText(markdown: proposal.assistantMarkdown)
      detailGrid
      HStack {
        if let appliedResult = proposal.appliedResult {
          Label(appliedResult.workflowScaffold.workflowId, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
        Spacer()
        Button {
          onApply()
        } label: {
          Label("Apply", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
        .disabled(proposal.appliedResult != nil)
      }
    }
    .padding(12)
    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }

  private var detailGrid: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
      row("Class", proposal.tagClass.classId)
      row("Tag", proposal.tag.name)
      row("Action", proposal.autoAction.actionId)
      row("Workflow", proposal.ingestionWorkflow.workflowId)
    }
    .font(.caption)
  }

  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .textSelection(.enabled)
    }
  }
}
