func renderSessionCommandStructuredPayload<Payload: Encodable>(
  _ payload: Payload,
  output: WorkflowOutputFormat,
  exitCode: CLIExitCode,
  stderr: String = "",
  jsonlRecorder: WorkflowRunJSONLRecorder?
) async -> CLICommandResult {
  let encoded = (try? jsonString(payload))
    ?? #"{"error":"failed to encode session command result","exitCode":1,"type":"session_encode_failed"}"# + "\n"
  let line = encoded + (encoded.hasSuffix("\n") ? "" : "\n")
  guard output == .jsonl else {
    return CLICommandResult(exitCode: exitCode, stdout: line, stderr: stderr)
  }
  await jsonlRecorder?.append(line)
  return CLICommandResult(
    exitCode: exitCode,
    stdout: await jsonlRecorder?.bufferedOutput() ?? "",
    stderr: stderr
  )
}
