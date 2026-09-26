// Build package: runtime resources never resolve relative to the working directory.
func fixBuildChecks() {
    let manager = FileManager.default
    guard let repository = runtimeRepositoryRoot(), repository.hasPrefix("/") else {
        require(false, "test builds name the repository with VIBE_TRACER_REPOSITORY")
        return
    }
    // A working directory laid out like the repository, holding planted look-alike resources.
    let planted = manager.temporaryDirectory.appendingPathComponent("vibe-planted-" + UUID().uuidString, isDirectory: true)
    let resources = ["scripts/usd_bridge.py", "build/ShaderResources/OpenPBR.metal",
                     "build/OIDN/lib/libOpenImageDenoise.2.dylib"]
    for relative in resources {
        let url = planted.appendingPathComponent(relative)
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        require(manager.createFile(atPath: url.path, contents: Data("#error planted\n".utf8)), "write planted \(relative)")
    }
    defer { try? manager.removeItem(at: planted) }
    let previous = manager.currentDirectoryPath
    require(manager.changeCurrentDirectoryPath(planted.path), "enter planted working directory")
    defer { _ = manager.changeCurrentDirectoryPath(previous) }

    for relative in resources {
        let plantedURL = planted.appendingPathComponent(relative)
        require(runtimeResourceURL(bundled: nil, repositoryPath: relative, repository: nil) == nil,
                "release resolution ignores the working directory for \(relative)")
        require(runtimeResourceURL(bundled: nil, repositoryPath: relative, repository: ".") == nil,
                "a relative repository root is rejected for \(relative)")
        require(runtimeResourceURL(bundled: plantedURL.deletingLastPathComponent().appendingPathComponent("missing"),
                                   repositoryPath: relative, repository: nil) == nil,
                "a missing bundled copy is not replaced by a working-directory copy for \(relative)")
        require(runtimeResourceURL(bundled: plantedURL, repositoryPath: relative, repository: repository) == plantedURL,
                "the bundled copy takes precedence for \(relative)")
        let resolved = runtimeResourceURL(bundled: nil, repositoryPath: relative, repository: repository)
        require(resolved?.path == URL(fileURLWithPath: repository).appendingPathComponent(relative).path,
                "test builds resolve \(relative) under the explicit repository")
    }
    let helper = USDImporter.helperURL?.resolvingSymlinksInPath().path
    require(helper == URL(fileURLWithPath: repository).appendingPathComponent("scripts/usd_bridge.py").resolvingSymlinksInPath().path,
            "the USD bridge comes from the repository, not the working directory")
    let shader = loadOpenPBRSource()
    require(!shader.contains("#error"), "OpenPBR.metal comes from the repository, not the working directory")
    require(shader.contains("Modified by Metal Vibe Tracer") && shader.contains("Licensed under the Apache License"),
            "the shipped OpenPBR source keeps its modification notice and upstream per-file license comments")
    require(OIDNDenoiser.isAvailable, "Open Image Denoise loads from the repository runtime, not a planted library")
    print("PASS: runtime resources resolve from the bundle or an explicit repository, never the working directory")
}
fixBuildChecks()
