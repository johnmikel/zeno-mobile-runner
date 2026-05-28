#!/usr/bin/env node
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const targets = [
  {
    key: "aarch64-macos.15.0",
    osBlock: "on_macos",
    cpuCheck: "Hardware::CPU.arm?",
  },
  {
    key: "x86_64-macos.15.0",
    osBlock: "on_macos",
    cpuCheck: "Hardware::CPU.intel?",
  },
  {
    key: "aarch64-linux-gnu",
    osBlock: "on_linux",
    cpuCheck: "Hardware::CPU.arm?",
  },
  {
    key: "x86_64-linux-gnu",
    osBlock: "on_linux",
    cpuCheck: "Hardware::CPU.intel?",
  },
];

function parseArgs(argv) {
  const args = {
    version: process.env.ZMR_VERSION,
    checksums: path.join(root, "dist", "SHA256SUMS"),
    out: path.join(root, "dist", "homebrew", "zmr.rb"),
    baseUrl: process.env.ZMR_RELEASE_BASE_URL,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--version") {
      args.version = argv[++index];
    } else if (arg === "--checksums") {
      args.checksums = path.resolve(argv[++index] ?? "");
    } else if (arg === "--out") {
      args.out = path.resolve(argv[++index] ?? "");
    } else if (arg === "--base-url") {
      args.baseUrl = argv[++index];
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (!args.version) throw new Error("missing --version or ZMR_VERSION");
  if (!args.baseUrl) {
    args.baseUrl = `https://github.com/johnmikel/zeno-mobile-runner/releases/download/v${args.version}`;
  }
  args.baseUrl = args.baseUrl.replace(/\/+$/, "");
  return args;
}

function parseChecksums(content) {
  const checksums = new Map();
  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.length === 0) continue;
    const match = line.match(/^([a-fA-F0-9]{64})\s+\*?(.+)$/);
    if (!match) throw new Error(`invalid checksum line: ${rawLine}`);
    checksums.set(path.basename(match[2]), match[1].toLowerCase());
  }
  return checksums;
}

function archiveName(version, target) {
  return `zmr-${version}-${target}.tar.gz`;
}

function formulaBlock({ osBlock, cpuCheck, name, url, sha }) {
  return `  ${osBlock} do
    if ${cpuCheck}
      url "${url}"
      sha256 "${sha}"
    end
  end`;
}

function generateFormula({ version, baseUrl, checksums }) {
  const blocks = targets.map((target) => {
    const name = archiveName(version, target.key);
    const sha = checksums.get(name);
    if (!sha) throw new Error(`missing checksum for ${name}`);
    return formulaBlock({
      ...target,
      name,
      url: `${baseUrl}/${name}`,
      sha,
    });
  });

  return `class Zmr < Formula
  desc "Agent-native mobile app test runner for React Native, Expo, Flutter, Android, and iOS"
  homepage "https://zmr.dev"
  license "MIT"
  version "${version}"

${blocks.join("\n\n")}

  def install
    bin.install "zmr"
    pkgshare.install "README.md" if File.exist?("README.md")
    pkgshare.install "docs" if Dir.exist?("docs")
    pkgshare.install "examples" if Dir.exist?("examples")
    pkgshare.install "schemas" if Dir.exist?("schemas")
    pkgshare.install "viewer" if Dir.exist?("viewer")
  end

  test do
    system "#{bin}/zmr", "version"
  end
end
`;
}

const args = parseArgs(process.argv.slice(2));
const checksums = parseChecksums(await readFile(args.checksums, "utf8"));
const formula = generateFormula({
  version: args.version,
  baseUrl: args.baseUrl,
  checksums,
});

await mkdir(path.dirname(args.out), { recursive: true });
await writeFile(args.out, formula);
console.log(`wrote ${args.out}`);
