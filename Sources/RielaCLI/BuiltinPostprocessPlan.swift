import RielaAddonSupport
import RielaCore

/// A runtime-owned option shared by native, private and container built-ins.
/// Removing it from the leaf request prevents double application in a worker.
struct BuiltinPostprocessPlan {
  var input: WorkflowAddonExecutionInput
  private let program: JSONDataTransform.Program?

  init(_ input: WorkflowAddonExecutionInput) throws {
    self.input = input
    guard input.addon.name.hasPrefix("riela/") || input.addon.name.hasPrefix("kaiba/"),
      let steps = input.addon.config?["postprocess"] else {
      program = nil
      return
    }
    let rendered = try renderAddonConfig(steps, variables: addonVariables(for: input))
    program = try JSONDataTransform.compile(rendered)
    self.input.addon.config?.removeValue(forKey: "postprocess")
  }

  func apply(to original: AdapterExecutionOutput) -> AdapterExecutionOutput {
    guard let program else { return original }
    var output = original
    if original.when["providerFailed"] == true {
      output.payload["postprocess"] = .object(["status": .string("skipped")])
      output.when["postprocessPassed"] = false
      output.when["postprocessFailed"] = false
      return output
    }
    do {
      // The provider payload is already held in memory and may repeat the
      // response (`data` and `response`); bound the picked values, not the
      // whole duplicated envelope.
      output.payload["processed"] = try program.run(.object(original.payload), checkInputSize: false)
      output.payload["postprocess"] = .object(["status": .string("ok")])
      output.when["postprocessPassed"] = true
      output.when["postprocessFailed"] = false
    } catch {
      // The provider operation already completed. Keep its output, completion
      // status and internal receipt; never turn shaping failure into replay.
      output.payload["postprocess"] = .object([
        "status": .string("failed"), "reason": .string("input-shape-or-limit"), "retryProvider": .bool(false)
      ])
      output.when["postprocessPassed"] = false
      output.when["postprocessFailed"] = true
    }
    return output
  }
}
