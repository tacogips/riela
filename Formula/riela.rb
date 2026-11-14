class Riela < Formula
  desc "Swift-native workflow runtime for cooperative multi-agent execution"
  homepage "https://github.com/tacogips/riela"
  version "0.1.9"
  license "MIT"

  livecheck do
    url :stable
    strategy :github_latest
  end

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/tacogips/riela/releases/download/v0.1.9/riela-0.1.9-darwin-arm64.tar.gz"
      sha256 "0b17e7ae2a3671ca2355254f041f975883d3f7eda8ae2050719a6100af94f770"
    else
      url "https://github.com/tacogips/riela/releases/download/v0.1.9/riela-0.1.9-darwin-x64.tar.gz"
      sha256 "ac5cb475659077b36922883525c764dad9e376385d6f05a03575f90ae52d5609"
    end
  end

  def install
    bin.install "bin/riela"
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/riela --help")
    (testpath/"addon-smoke").mkpath
    (testpath/"addon-smoke/workflow.json").write <<~JSON
      {
        "workflowId": "addon-smoke",
        "description": "Smoke workflow that requires built-in add-on package resolution.",
        "defaults": {
          "maxLoopIterations": 3,
          "nodeTimeoutMs": 120000
        },
        "entryStepId": "send-reply",
        "nodes": [
          {
            "id": "send-reply",
            "addon": {
              "name": "riela/chat-reply-worker",
              "version": "1",
              "config": {
                "textTemplate": "ok",
                "visibility": "public",
                "threadPolicy": "same-thread",
                "onMissingTarget": "dry-run"
              }
            }
          }
        ],
        "steps": [
          {
            "id": "send-reply",
            "nodeId": "send-reply",
            "role": "worker"
          }
        ]
      }
    JSON
    usage = shell_output(
      "#{bin}/riela workflow usage addon-smoke --workflow-definition-dir #{testpath} --output json",
    )
    assert_match '"workflowId":"addon-smoke"', usage
    assert_match %r{riela\\?/chat-reply-worker}, usage
  end
end
