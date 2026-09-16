#!/usr/bin/env python3
"""Check real status/progress views offscreen; no user app or downloads are used."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/DownloadViews.swift").read_text()
models = source[:source.index("// MARK: - Download Input Metrics")]
progress = source[source.index("// MARK: - Download Progress Bar Views"):source.index("@MainActor\nfinal class DownloadProgressStackView")]
empty = (root / "Sources/EmptyStateViews.swift").read_text().split("final class DropZoneView", 1)[0]
harness = r"""
@main enum Check {
 @MainActor static func main() {
  _ = NSApplication.shared
  let controller = NSViewController()
  controller.view = NSView(frame: NSRect(x: 0,y: 0,width: 920,height: 620))
  let empty = EmptyStateView(title: "Downloads", symbolName: "photo", message: "Ready")
  let bar = DownloadTaskProgressBarView(frame: .zero)
  empty.translatesAutoresizingMaskIntoConstraints = false
  bar.translatesAutoresizingMaskIntoConstraints = false
  controller.view.addSubview(empty)
  controller.view.addSubview(bar)
  NSLayoutConstraint.activate([
   empty.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor), empty.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
   empty.topAnchor.constraint(equalTo: controller.view.topAnchor), empty.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
   bar.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 80),bar.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor,constant: -80),
   bar.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor,constant: -40), bar.heightAnchor.constraint(equalToConstant: 40)
  ])
  let window = NSWindow(contentViewController: controller)
  window.setContentSize(NSSize(width: 920, height: 620))
  controller.view.layoutSubtreeIfNeeded()
  let before = window.frame.size
  empty.message = String(repeating: "Very-long-download-result-", count: 100)
  bar.update(with: DownloadProgressItem(id: UUID(),title: "Downloading",detail: String(repeating: "long-detail-",count: 100),completedCount: 0,totalCount: 1,currentUnitProgress: 0.2,isActive: true),stackIndex: 0)
  controller.view.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  controller.view.layoutSubtreeIfNeeded()
  func descendants(_ view: NSView) -> [NSView] {
   view.subviews.flatMap { [$0] + descendants($0) }
  }
  let fill = descendants(bar).first { $0 is DownloadFluidColorView }!
  for fraction in [CGFloat(0), 0.01, 0.58, 1] {
   bar.update(with: DownloadProgressItem(id: UUID(),title: "Downloading",detail: "",completedCount: 0,totalCount: 1,currentUnitProgress: fraction,isActive: true),stackIndex: 0)
   controller.view.layoutSubtreeIfNeeded()
   precondition(abs(fill.frame.width - bar.bounds.width * fraction) < 0.5, "Progress width must match real fraction")
  }
  print("Progress geometry passed: 0%, 1%, 58%, 100%")
  print("before=\(before) after=\(window.frame.size)")
  if CommandLine.arguments.contains("--assert") { precondition(window.frame.size == before) }
 }
}
"""

with tempfile.TemporaryDirectory(prefix="hermes-window-layout-") as directory:
    fixture = Path(directory) / "WindowLayout.swift"
    binary = Path(directory) / "WindowLayout"
    fixture.write_text(models + progress + empty + harness)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", f"{platform.machine()}-apple-macos27.0", str(fixture), "-o", str(binary)], check=True)
    subprocess.run([str(binary), "--assert"], check=True)
