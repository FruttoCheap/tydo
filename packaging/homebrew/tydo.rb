# Copy this into FruttoCheap/homebrew-tap as Formula/tydo.rb.
# Update url + sha256 from the output of packaging/release-cli.sh on every release.
class Tydo < Formula
  desc "Local-first task manager CLI with pluggable LLM providers"
  homepage "https://github.com/FruttoCheap/tydo"
  url "https://github.com/FruttoCheap/tydo/releases/download/v1.2.0/tydo-1.2.0-macos-universal.tar.gz"
  sha256 "b8f87dfd4c0c9ec5449faf27ee840d617eeff0be7acca2121ab939ca5fc6d0f1"
  license "MIT"

  # AppKit, SwiftData and PDFKit — macOS only, and Sonoma is the floor.
  depends_on macos: :sonoma

  def install
    bin.install "tydo"
  end

  def caveats
    <<~EOS
      Tydo talks to any OpenAI-compatible server. For a fully local setup:
        ollama pull llama3.2
        ollama pull nomic-embed-text

      Then check everything is wired up:
        tydo doctor
    EOS
  end

  test do
    output = shell_output("#{bin}/tydo version")
    assert_match "\"protocolVersion\" : 1", output
    # doctor reports failed checks as data and still exits 0, so this passes on
    # a CI box with no model server running.
    assert_match "\"checks\"", shell_output("TYDO_DATA_DIR=#{testpath} #{bin}/tydo doctor")
  end
end
