# Homebrew formula for pdf.zig.
#
# This is the canonical source — at GA time it gets copied into the
# `laurentfabre/homebrew-pdf.zig` tap repo so users can install via:
#
#   brew tap laurentfabre/pdf.zig
#   brew install pdf.zig
#
# The placeholder SHA256s below are replaced by `scripts/update-formula.sh`
# after a release is cut. That script reads `release/SHA256SUMS` produced
# by the GH Actions release workflow and rewrites the four `sha256` lines.

class PdfZig < Formula
  desc "PDF -> Markdown extraction CLI, NDJSON-streaming, optimized for LLM consumers"
  homepage "https://github.com/laurentfabre/pdf.zig"
  version "1.0-rc2"
  license "CC0-1.0"

  base_url = "https://github.com/laurentfabre/pdf.zig/releases/download/v#{version}"

  on_macos do
    on_arm do
      url "#{base_url}/pdf.zig-v#{version}-aarch64-macos.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "#{base_url}/pdf.zig-v#{version}-x86_64-macos.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  on_linux do
    on_arm do
      url "#{base_url}/pdf.zig-v#{version}-aarch64-linux.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "#{base_url}/pdf.zig-v#{version}-x86_64-linux.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  def install
    bin.install "bin/pdf.zig"
    bin.install "bin/zpdf"
    lib.install Dir["lib/*"] if Dir.exist?("lib")
    doc.install "README.md", "LICENSE"
  end

  test do
    # Smoke: --version must exit 0 and print a version string.
    assert_match(/pdf\.zig \d/, shell_output("#{bin}/pdf.zig --version"))
    # Help text must mention the streaming-default mode.
    assert_match(/NDJSON/, shell_output("#{bin}/pdf.zig --help"))
  end
end
