// Swift 6 package: the app and this suite compile in the Swift 6 language mode (R-133).
func fixSwift6Checks() {
  #if !swift(>=6)
    require(false, "tests/harness.py compiles the suite in the Swift 6 language mode")
  #endif
  guard let repository = runtimeRepositoryRoot() else {
    require(false, "test builds name the repository with VIBE_TRACER_REPOSITORY")
    return
  }
  func text(_ relative: String) -> String {
    (try? String(contentsOfFile: repository + "/" + relative, encoding: .utf8)) ?? ""
  }
  let appCompile = text("build.sh").split(separator: "\n").filter { $0.hasPrefix("xcrun swiftc ") }
  require(appCompile.count == 1 && appCompile[0].contains(" -swift-version 6 "),
          "build.sh compiles the app in the Swift 6 language mode")
  require(text("tests/harness.py").contains("'swiftc', '-O', '-swift-version', '6',"),
          "tests/harness.py compiles checks and benchmarks in the Swift 6 language mode")
  print("PASS: fix-swift6 app, checks and benchmarks compile in the Swift 6 language mode (R-133)")
}
fixSwift6Checks()
