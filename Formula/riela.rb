class Riela < Formula
  desc "Swift-native workflow runtime for cooperative multi-agent execution"
  homepage "https://github.com/tacogips/riela"
  version "0.1.15"
  license "MIT"

  livecheck do
    url :stable
    strategy :github_latest
  end

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/tacogips/riela/releases/download/v0.1.15/riela-0.1.15-darwin-arm64.tar.gz"
      sha256 "0b85d7d5164ac77b2c24bad58c4385b543baed9db314b01abae7b0b63b056fba"
    else
      url "https://github.com/tacogips/riela/releases/download/v0.1.15/riela-0.1.15-darwin-x64.tar.gz"
      sha256 "fbbfa60db82666a7d9b2fd49e57ddf92b7472f22be7f08ad07dbeacfe60151a7"
    end
  end

  on_linux do
    odie "riela Swift Homebrew archives are currently macOS-only; Linux requires a reviewed Swift Linux build contract"
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
