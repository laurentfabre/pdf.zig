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
  version "1.0.1"
  license "CC0-1.0"

  base_url = "https://github.com/laurentfabre/pdf.zig/releases/download/v#{version}"

  on_macos do
    on_arm do
      url "#{base_url}/pdf.zig-v#{version}-aarch64-macos.tar.gz"
      sha256 "91b552b74158f1a8d22fe9d43275363e8cabbf181351ac2a10944ea8fed220d9"
    end
    on_intel do
      url "#{base_url}/pdf.zig-v#{version}-x86_64-macos.tar.gz"
      sha256 "7a5bf4cba7bec77b552cd6a939950d9577896aee45de1f4e9e2a0668fec2a3f3"
    end
  end

  on_linux do
    on_arm do
      url "#{base_url}/pdf.zig-v#{version}-aarch64-linux.tar.gz"
      sha256 "1e5b65823905ed8886ecdbfbd2794a2b6bcab9cb5758f4f2a43cb82742c48cbb"
    end
    on_intel do
      url "#{base_url}/pdf.zig-v#{version}-x86_64-linux.tar.gz"
      sha256 "f7e56a4e43724479928666430f1fd8fca98ea1126c117bc97666a963fd4774b4"
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
