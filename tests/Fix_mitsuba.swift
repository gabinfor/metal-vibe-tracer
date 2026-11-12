// Mitsuba scene import (MitsubaImporter), XML layer: <default> values and $variables, global <ref> ids
// (including a BSDF nested in another), <include>, transforms in document order, the Mitsuba 0.6 property
// names, the depth and size limits on hostile files, and the not-a-scene error; shapes (mesh files and analytic
// shapes as world-space triangles); the values taken from Mitsuba (IORs, conductors, plastic ratios); materials
// (BSDFs, textures, emitters and interior media as OpenPBR MaterialX documents).
@MainActor func fixMitsubaChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("mitsuba", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  func write(_ name: String, _ text: String) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
  func requireThrows(_ fragment: String, _ body: () throws -> Void) {
    do { try body() } catch {
      require("\(error)".contains(fragment) || error.localizedDescription.contains(fragment),
        "error mentions '\(fragment)' (got \(error))")
      return
    }
    require(false, "expected an error mentioning '\(fragment)'")
  }

  let defaultsURL = try write("defaults.xml", """
    <scene version="3.0.0">
      <default name="d" value="7"/>
      <default name="res" value="64"/>
      <default name="mesh" value="box"/>
      <integrator type="path"><integer name="max_depth" value="$d"/></integrator>
      <sensor type="perspective">
        <transform name="to_world"><lookat origin="0, 0, 0" target="0, 0, 1" up="0, 1, 0"/></transform>
        <film type="hdrfilm"><integer name="width" value="$res"/><string name="tag" value="r$res.exr"/></film>
      </sensor>
      <bsdf type="bumpmap">
        <texture type="bitmap" name="arrays"><string name="filename" value="models/$mesh.png"/></texture>
        <bsdf type="diffuse" id="inner"><rgb name="reflectance" value="0.2 0.4 0.6"/></bsdf>
      </bsdf>
      <shape type="obj">
        <string name="filename" value="$mesh.obj"/>
        <transform name="to_world"><scale value="2"/><translate x="1" y="0" z="0"/></transform>
        <ref id="inner"/>
        <ref name="extra" id="late"/>
      </shape>
      <shape type="sphere">
        <transform name="to_world"><translate x="1" y="0" z="0"/><scale value="2"/></transform>
        <transform name="to_uv"><matrix value="2 0 0.5  0 3 0.25  0 0 1"/></transform>
      </shape>
      <shape type="cube">
        <transform name="to_world"><rotate y="1" angle="90"/></transform>
        <transform name="to_uv"><matrix value="1 0 0 5  0 1 0 6  0 0 1 7  0 0 0 1"/></transform>
      </shape>
      <include filename="extra/part.xml"/>
      <bsdf type="plastic" id="late"/>
    </scene>
    """)
  try FileManager.default.createDirectory(at: folder.appendingPathComponent("extra"), withIntermediateDirectories: true)
  _ = try write("extra/part.xml", """
    <scene version="3.0.0">
      <emitter type="constant"><rgb name="radiance" value="1"/></emitter>
      <include filename="more.xml"/>
    </scene>
    """)
  _ = try write("extra/more.xml", """
    <scene version="3.0.0"><emitter type="point"><float name="intensity" value="$d"/></emitter></scene>
    """)

  let scene = try MitsubaImporter.Scene(url: defaultsURL)
  let shapes = scene.root.children.filter { $0.tag == "shape" }
  let shape = shapes[0]
  require(scene.root.children.first { $0.tag == "integrator" }?.float("max_depth") == 7, "defaults substitute")
  require(scene.root.children.contains { $0.tag == "default" || $0.tag == "include" } == false, "defaults and includes are consumed")
  let film = scene.root.children.first { $0.tag == "sensor" }?.child("film")
  require(film?.float("width") == 64 && film?.string("tag") == "r64.exr" && shape.string("filename") == "box.obj",
    "a variable inside a longer attribute string")
  require(shape.child("bsdf")?.id == "inner", "a ref resolves to a BSDF nested in another")
  require(shape.child("bsdf")?.rgb("reflectance") == SIMD3(0.2, 0.4, 0.6), "a resolved ref carries its children")
  require(shape.child("extra")?.type == "plastic", "a ref resolves to a node defined later and keeps its own name")
  require(shape.transform("to_world") * SIMD4(1, 0, 0, 1) == SIMD4(3, 0, 0, 1), "scale then translate")
  require(shapes[1].transform("to_world") * SIMD4(1, 0, 0, 1) == SIMD4(4, 0, 0, 1), "translate then scale")
  let rotated = shapes[2].transform("to_world") * SIMD4(0, 0, 1, 1)
  require(abs(rotated.x - 1) < 1e-6 && abs(rotated.z) < 1e-6, "rotate 90 degrees about y")
  require(shapes[1].transform("to_uv") * SIMD4(1, 1, 0, 1) == SIMD4(2.5, 3.25, 0, 1), "a 3 x 3 matrix is a uv transform")
  require(shapes[2].transform("to_uv") * SIMD4(0, 0, 0, 1) == SIMD4(5, 6, 7, 1), "a 4 x 4 matrix is row-major")
  require(shape.transform("missing") == matrix_identity_float4x4, "an absent transform is the identity")
  let look = scene.root.children.first { $0.tag == "sensor" }!.transform("to_world")
  require(look * SIMD4(0, 0, 1, 0) == SIMD4(0, 0, 1, 0) && look * SIMD4(1, 0, 0, 0) == SIMD4(1, 0, 0, 0)
    && look * SIMD4(0, 1, 0, 0) == SIMD4(0, 1, 0, 0), "lookat along +z with +y up")
  let emitters = scene.root.children.filter { $0.tag == "emitter" }
  require(emitters.map(\.type) == ["constant", "point"] && emitters[1].float("intensity") == 7 && emitters[0].rgb("radiance") == SIMD3(1, 1, 1),
    "includes are spliced in place, nested, with the variables in scope")

  let old = try MitsubaImporter.Scene(url: try write("v06.xml", """
    <scene version="0.6.0">
      <integrator type="path"><integer name="maxDepth" value="9"/></integrator>
      <sensor type="perspective">
        <float name="fovAxis" value="1"/>
        <transform name="toWorld"><lookAt origin="0, 0, 5" target="0, 0, 0" up="0, 1, 0"/></transform>
      </sensor>
      <bsdf type="dielectric" id="water"><float name="intIOR" value="1.33"/><float name="someOtherName" value="2"/></bsdf>
      <bsdf type="diffuse" id="tinted"><srgb name="diffuseReflectance" value="#808080"/></bsdf>
      <bsdf type="diffuse" id="plain"><srgb name="reflectance" value="0.5 0.5 0.5"/></bsdf>
      <texture type="bitmap" id="tex"><float name="uscale" value="4"/><float name="vscale" value="2"/></texture>
      <shape type="obj"><transform name="toWorld"><translate x="0" y="1" z="0"/></transform><ref id="water"/></shape>
    </scene>
    """))
  let oldShape = old.root.children.first { $0.tag == "shape" }!
  let oldBSDF = old.root.children.first { $0.id == "water" }!
  let oldIntegrator = old.root.children.first { $0.tag == "integrator" }!
  require(oldShape.child("to_world") != nil && oldBSDF.float("int_ior") == 1.33
    && oldIntegrator.float("max_depth") == 9, "0.6 names are renamed")
  require(oldBSDF.float("someOtherName") == 2, "unknown camelCase names are left as they are")
  require(old.root.children.first { $0.tag == "sensor" }?.float("fov_axis") == 1, "0.6 property fovAxis")
  let oldLook = old.root.children.first { $0.tag == "sensor" }!.transform("to_world")
  require(oldLook * SIMD4(0, 0, 0, 1) == SIMD4(0, 0, 5, 1) && oldLook * SIMD4(0, 0, 1, 0) == SIMD4(0, 0, -1, 0), "<lookAt> is lookat")
  let grey = old.root.children.first { $0.id == "tinted" }!.rgb("diffuse_reflectance")
  require(grey.map { abs($0.x - 0.2158605) < 1e-4 && $0.x == $0.y && $0.y == $0.z } == true, "diffuse's srgb values are linearized in a 0.6 file")
  require(old.root.children.first { $0.id == "plain" }?.children.first?.tag == "rgb", "the srgb element becomes an rgb element")
  let uv = old.root.children.first { $0.id == "tex" }!
  require(uv.float("uscale") == nil && uv.transform("to_uv") * SIMD4(1, 1, 0, 1) == SIMD4(4, 2, 0, 1), "uscale and vscale become a to_uv scale")
  let current = try MitsubaImporter.Scene(url: try write("v3-names.xml", """
    <scene version="3.0.0"><bsdf type="dielectric" id="g"><float name="intIOR" value="1.33"/></bsdf></scene>
    """))
  require(current.root.children[0].float("intIOR") == 1.33 && current.root.children[0].float("int_ior") == nil, "the rename is for 0.6 files only")
  let unversioned = try MitsubaImporter.Scene(url: try write("noversion.xml", #"<scene><bsdf type="dielectric"><float name="intIOR" value="1.33"/></bsdf></scene>"#))
  require(unversioned.root.children[0].float("intIOR") == 1.33, "a missing version counts as 3 (no 0.6 renames)")

  var report = scene
  report.note("a"); report.note("b"); report.note("a")
  require(report.report == ["a", "b"], "report lines are kept once")

  let otherXMLURL = try write("other.xml", "<svg/>")
  requireThrows("not a Mitsuba scene") { _ = try MitsubaImporter.Scene(url: otherXMLURL) }
  let badRefURL = try write("badref.xml", #"<scene version="3.0.0"><shape type="obj"><ref id="missing"/></shape></scene>"#)
  requireThrows("undefined reference 'missing'") { _ = try MitsubaImporter.Scene(url: badRefURL) }
  let badVariableURL = try write("badvar.xml", #"<scene version="3.0.0"><integrator type="path"><integer name="max_depth" value="$nope"/></integrator></scene>"#)
  requireThrows("undefined variable '$nope'") { _ = try MitsubaImporter.Scene(url: badVariableURL) }
  let loopA = try write("loop-a.xml", #"<scene version="3.0.0"><include filename="loop-b.xml"/></scene>"#)
  _ = try write("loop-b.xml", #"<scene version="3.0.0"><include filename="loop-a.xml"/></scene>"#)
  requireThrows("include cycle") { _ = try MitsubaImporter.Scene(url: loopA) }
  let selfRef = try write("selfref.xml", #"<scene version="3.0.0"><bsdf type="twosided" id="a"><ref id="a"/></bsdf></scene>"#)
  requireThrows("reference cycle") { _ = try MitsubaImporter.Scene(url: selfRef) }
  requireThrows("Mitsuba:") { _ = try MitsubaImporter.Scene(url: folder.appendingPathComponent("nothing.xml")) }

  // Review fixes: degenerate lookat, hex colours, hostile files, include roots, duplicate ids, source folders,
  // number parsing and the remaining variable forms.
  func isFinite(_ m: simd_float4x4) -> Bool { (0..<4).allSatisfy { c in (0..<4).allSatisfy { m[c][$0].isFinite } } }
  let looks = try MitsubaImporter.Scene(url: try write("lookat.xml", """
    <scene version="3.0.0">
      <sensor type="perspective"><transform name="to_world"><lookat origin="0, 0, 0" target="0, 1, 0"/></transform></sensor>
      <sensor type="perspective"><transform name="to_world"><lookat origin="1 2 3" target="1 2 8" up="0 0 2"/></transform></sensor>
      <sensor type="perspective"><transform name="to_world"><lookat origin="0, 0, 0" target="0, 0, 1" up="0, 1, 0"/></transform></sensor>
    </scene>
    """))
  let sensors = looks.root.children
  let noUp = sensors[0].transform("to_world"), parallelUp = sensors[1].transform("to_world")
  require(isFinite(noUp) && isFinite(parallelUp), "lookat without an up, or with an up parallel to the direction, is finite")
  require(noUp * SIMD4(0, 0, 1, 0) == SIMD4(0, 1, 0, 0) && abs(simd_dot(noUp.columns.0, noUp.columns.1)) < 1e-6,
    "the replaced up keeps the view direction and an orthogonal frame")
  require(parallelUp * SIMD4(0, 0, 0, 1) == SIMD4(1, 2, 3, 1) && parallelUp * SIMD4(0, 0, 1, 0) == SIMD4(0, 0, 1, 0), "parallel up keeps origin and direction")
  requireThrows("lookat needs distinct origin and target") {
    _ = try MitsubaImporter.Scene(url: try write("lookat-same.xml", #"<scene version="3.0.0"><sensor type="perspective"><transform name="to_world"><lookat origin="1, 2, 3" target="1 2 3" up="0 1 0"/></transform></sensor></scene>"#))
  }

  for (name, origin, target) in [("origin-only", #"origin="0 0 0""#, ""), ("target-only", "", #"target="0, 0, 0""#)] {
    requireThrows("lookat needs distinct origin and target") {
      _ = try MitsubaImporter.Scene(url: try write("lookat-\(name).xml", #"<scene version="3.0.0"><sensor type="perspective"><transform name="to_world"><lookat \#(origin) \#(target)/></transform></sensor></scene>"#))
    }
  }
  let offOrigin = try MitsubaImporter.Scene(url: try write("lookat-off.xml", #"<scene version="3.0.0"><sensor type="perspective"><transform name="to_world"><lookat origin="0 0 1"/></transform></sensor></scene>"#))
  require(isFinite(offOrigin.root.children[0].transform("to_world")), "a lookat with only an origin away from 0 0 0 is finite")

  let colours = try MitsubaImporter.Scene(url: try write("hex.xml", """
    <scene version="3.0.0">
      <bsdf type="diffuse" id="long"><rgb name="reflectance" value="#6d7185"/></bsdf>
      <bsdf type="diffuse" id="short"><rgb name="reflectance" value="#f80"/></bsdf>
      <bsdf type="diffuse" id="bad"><rgb name="reflectance" value="#12"/></bsdf>
      <bsdf type="diffuse" id="spaced"><rgb name="reflectance" value=" 0.5 , 0.25  0.125 "/></bsdf>
      <bsdf type="diffuse" id="plus"><rgb name="reflectance" value="#+ff"/></bsdf>
      <bsdf type="diffuse" id="minus"><rgb name="reflectance" value="#-12"/></bsdf>
      <bsdf type="diffuse" id="plusLong"><rgb name="reflectance" value="#+12345"/></bsdf>
    </scene>
    """))
  func colour(_ id: String) -> SIMD3<Float>? { colours.root.children.first { $0.id == id }?.rgb("reflectance") }
  func srgbToLinear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
  let long = colour("long") ?? .zero, short = colour("short") ?? .zero
  require(simd_length(long - SIMD3(srgbToLinear(0x6d / 255), srgbToLinear(0x71 / 255), srgbToLinear(0x85 / 255))) < 1e-6, "#rrggbb is sRGB decoded")
  require(simd_length(short - SIMD3(1, srgbToLinear(8 / 15), 0)) < 1e-6, "#rgb is sRGB decoded")
  require(colour("bad") == nil && colour("spaced") == SIMD3(0.5, 0.25, 0.125), "a bad hex colour is nil; commas and spaces mix")
  require(colour("plus") == nil && colour("minus") == nil && colour("plusLong") == nil, "a sign after # is not a hex digit")
  let hexOld = try MitsubaImporter.Scene(url: try write("hex06.xml", ##"<scene version="0.6.0"><bsdf type="diffuse" id="d"><srgb name="reflectance" value="#f80"/></bsdf></scene>"##))
  require(hexOld.root.children[0].rgb("reflectance").map { simd_length($0 - short) < 1e-6 } == true, "a 0.6 srgb accepts #rgb")

  let outer = try write("outer.xml", """
    <scene version="3.0.0">
      <include filename="sub/inc.xml"/>
      <shape type="obj"><string name="filename" value="own.obj"/></shape>
    </scene>
    """)
  try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
  _ = try write("sub/inc.xml", #"<scene version="3.0.0"><shape type="obj"><string name="filename" value="meshes/part.obj"/></shape></scene>"#)
  let nested = try MitsubaImporter.Scene(url: outer)
  require(nested.root.children[0].url("filename")?.standardizedFileURL == folder.appendingPathComponent("sub/meshes/part.obj").standardizedFileURL
    && nested.root.children[1].url("filename")?.standardizedFileURL == folder.appendingPathComponent("own.obj").standardizedFileURL
    && nested.root.children[1].url("missing") == nil, "url resolves against the folder of the file the element came from")

  require(nested.root.children[1].url("filename") != nil, "a non-empty string is a URL")
  let emptyPath = try MitsubaImporter.Scene(url: try write("empty-path.xml", #"<scene version="3.0.0"><shape type="obj"><string name="filename" value=""/></shape></scene>"#))
  require(emptyPath.root.children[0].url("filename") == nil, "an empty string is not a URL (it would resolve to the folder itself)")
  let refMain = try write("ref-main.xml", """
    <scene version="3.0.0">
      <include filename="sub/defs.xml"/>
      <shape type="obj"><ref id="wood"/></shape>
    </scene>
    """)
  _ = try write("sub/defs.xml", #"<scene version="3.0.0"><bsdf type="diffuse" id="wood"><string name="filename" value="wood.png"/></bsdf></scene>"#)
  let referenced = try MitsubaImporter.Scene(url: refMain)
  require(referenced.root.children.first { $0.tag == "shape" }?.child("bsdf")?.url("filename")?.standardizedFileURL == folder.appendingPathComponent("sub/wood.png").standardizedFileURL,
    "a <ref> to a target defined in an included file carries that file's folder")

  requireThrows("is not a Mitsuba scene") {
    _ = try MitsubaImporter.Scene(url: try write("inc-bad.xml", #"<scene version="3.0.0"><include filename="other.xml"/></scene>"#))
  }
  requireThrows("duplicate id 'a'") {
    _ = try MitsubaImporter.Scene(url: try write("dup-top.xml", #"<scene version="3.0.0"><bsdf type="diffuse" id="a"/><bsdf type="plastic" id="a"/></scene>"#))
  }
  requireThrows("duplicate id 'n'") {
    _ = try MitsubaImporter.Scene(url: try write("dup-nested.xml", #"<scene version="3.0.0"><bsdf type="diffuse" id="n"/><bsdf type="twosided"><bsdf type="plastic" id="n"/></bsdf></scene>"#))
  }
  requireThrows("cannot read") {
    _ = try MitsubaImporter.Scene(url: try write("malformed.xml", "<scene version=\"3.0.0\"><bsdf></scene>"))
  }
  requireThrows("cannot read") {
    _ = try MitsubaImporter.Scene(url: try write("entity.xml", #"<!DOCTYPE scene [<!ENTITY x SYSTEM "file:///etc/hosts">]><scene version="3.0.0"><string name="s" value="&x;"/></scene>"#))
  }

  let misc = try MitsubaImporter.Scene(url: try write("misc.xml", """
    <scene version="3.0.0">
      <default name="res" value="32"/><default name="resx" value="48"/><default name="res" value="99"/>
      <default name="kind" value="diffuse"/>
      <bsdf type="$kind" id="b"><integer name="spaced" value=" 7 "/><boolean name="yes" value="true"/><boolean name="no" value=" False "/>
        <float name="w" value="$resx"/><float name="v" value="$res"/><boolean name="odd" value="maybe"/></bsdf>
    </scene>
    """))
  let b = misc.root.children[0]
  require(b.type == "diffuse" && b.attributes["type"] == "diffuse", "a variable in a type attribute")
  require(b.float("spaced") == 7, "whitespace around a number is trimmed")
  require(b.bool("yes") == true && b.bool("no") == false && b.bool("odd") == nil && b.bool("w") == nil, "bool reads true and false only")
  require(b.float("w") == 48 && b.float("v") == 32, "$resx is not $res followed by x; the first default wins")
  // A lookat whose origin is one number repeated (as Node.operation reads it) equal to its target is rejected.
  requireThrows("lookat needs distinct origin and target") {
    _ = try MitsubaImporter.Scene(url: try write("lookat-repeated.xml", #"<scene version="3.0.0"><sensor type="perspective"><transform name="to_world"><lookat origin="1" target="1, 1, 1"/></transform></sensor></scene>"#))
  }

  // Depth and size bombs fail with an error instead of exhausting the 512 KB stack of the import worker or memory.
  // The scene read on a thread with the worker's 512 KB stack: its error, or nil.
  func importStackError(_ url: URL) -> String? {
    final class Outcome: @unchecked Sendable { var error: String? }
    let outcome = Outcome(), done = DispatchSemaphore(value: 0)
    let thread = Thread {
      do { _ = try MitsubaImporter.Scene(url: url) } catch { outcome.error = "\(error) \(error.localizedDescription)" }
      done.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    done.wait()
    return outcome.error
  }
  // References 5,000 deep, each definition naming the next: the chain of references is cut at maxReferenceDepth.
  let links = 5000
  let forward = (0..<links).map { #"<bsdf type="twosided" id="b\#($0)"><ref id="b\#($0 + 1)"/></bsdf>"# }.joined()
  let forwardURL = try write("ref-chain.xml", #"<scene version="3.0.0">\#(forward)<bsdf type="diffuse" id="b\#(links)"/></scene>"#)
  requireThrows("references nested too deeply") { _ = try MitsubaImporter.Scene(url: forwardURL) }
  // The same chain defined from its end: every reference finds its target resolved, and the resolved tree's depth
  // is what stops it.
  let backward = (0..<links).reversed().map { #"<bsdf type="twosided" id="b\#($0)"><ref id="b\#($0 + 1)"/></bsdf>"# }.joined()
  let backwardURL = try write("ref-chain-reversed.xml", #"<scene version="3.0.0"><bsdf type="diffuse" id="b\#(links)"/>\#(backward)</scene>"#)
  requireThrows("nested more than \(MitsubaImporter.maxElementDepth) deep") { _ = try MitsubaImporter.Scene(url: backwardURL) }
  // Elements 10,000 deep in the file, read on the worker's stack: stopped before XMLDocument builds (and would release)
  // the tree.
  let deep = String(repeating: #"<bsdf type="twosided">"#, count: 10_000) + #"<bsdf type="diffuse"/>"# + String(repeating: "</bsdf>", count: 10_000)
  let deepURL = try write("deep.xml", #"<scene version="3.0.0">\#(deep)</scene>"#)
  let deepError = importStackError(deepURL)
  require(deepError?.contains("nested more than \(MitsubaImporter.maxElementDepth) deep") == true,
    "elements 10,000 deep fail on a 512 KB stack (\(deepError ?? "no error"))")
  // Nested internal entities (a6 is 10^7 characters), then elements 3,000 deep: the streaming pass stops at the entity
  // declarations, so XMLDocument never expands them or builds the tree.
  var entities = #"<!ENTITY a0 "xxxxxxxxxx">"#
  for i in 1...6 { entities += "<!ENTITY a\(i) \"\(String(repeating: "&a\(i - 1);", count: 10))\">" }
  let entityURL = try write("entity-bomb.xml", "<!DOCTYPE scene [\(entities)]><scene version=\"3.0.0\">&a6;"
    + String(repeating: "<x>", count: 3000) + String(repeating: "</x>", count: 3000) + "</scene>")
  let entityError = importStackError(entityURL)
  require(entityError?.contains("cannot read entity-bomb.xml") == true, "nested entities fail cleanly on a 512 KB stack (\(entityError ?? "no error"))")
  // Elements within the limit in each file, deeper together through an include.
  let half = MitsubaImporter.maxElementDepth / 2 + 1
  let halfDeep = String(repeating: "<bsdf type=\"twosided\">", count: half) + "<bsdf type=\"diffuse\"/>" + String(repeating: "</bsdf>", count: half)
  _ = try write("half-inner.xml", #"<scene version="3.0.0">\#(halfDeep)</scene>"#)
  let halfURL = try write("half-outer.xml", #"<scene version="3.0.0">\#(halfDeep.replacingOccurrences(of: "<bsdf type=\"diffuse\"/>", with: #"<include filename="half-inner.xml"/>"#))</scene>"#)
  requireThrows("nested more than \(MitsubaImporter.maxElementDepth) deep") { _ = try MitsubaImporter.Scene(url: halfURL) }
  // Includes 20 files deep: Mitsuba's limit of 15 files open at once.
  for i in 0..<20 { _ = try write("chain\(i).xml", #"<scene version="3.0.0"><include filename="chain\#(i + 1).xml"/></scene>"#) }
  _ = try write("chain20.xml", #"<scene version="3.0.0"/>"#)
  requireThrows("includes nested more than 15 files deep") { _ = try MitsubaImporter.Scene(url: folder.appendingPathComponent("chain0.xml")) }
  _ = try write("chain14.xml", #"<scene version="3.0.0"/>"#)
  _ = try MitsubaImporter.Scene(url: folder.appendingPathComponent("chain0.xml"))
  // Nested defaults that repeat a variable: 1,000 characters, then 1,000 copies (1,000,000 bytes, allowed), then 10 of
  // those.
  let bomb = try write("bomb.xml", """
    <scene version="3.0.0">
      <default name="a" value="\(String(repeating: "x", count: 1000))"/>
      <default name="b" value="\(String(repeating: "$a", count: 1000))"/>
      <default name="c" value="\(String(repeating: "$b", count: 10))"/>
    </scene>
    """)
  requireThrows("a value with '$b' expands beyond 1 MB") { _ = try MitsubaImporter.Scene(url: bomb) }
  // Values within that limit, beyond maxSubstitutedTotal together: $b (1,000,000 bytes) in one value more than the
  // total holds.
  let uses = MitsubaImporter.maxSubstitutedTotal / 1_000_000 + 1
  let spread = try write("bomb-spread.xml", """
    <scene version="3.0.0">
      <default name="a" value="\(String(repeating: "x", count: 1000))"/>
      <default name="b" value="\(String(repeating: "$a", count: 1000))"/>
      \((0..<uses).map { #"<float name="x\#($0)" value="$b"/>"# }.joined())
    </scene>
    """)
  requireThrows("variables expand beyond \(MitsubaImporter.maxSubstitutedTotal >> 20) MB in all") { _ = try MitsubaImporter.Scene(url: spread) }
  // Includes that fan out: n includes of a file that includes 32 files are 33 n includes, at most maxIncludes.
  _ = try write("fan-leaf.xml", #"<scene version="3.0.0"/>"#)
  _ = try write("fan-middle.xml", #"<scene version="3.0.0">\#(String(repeating: #"<include filename="fan-leaf.xml"/>"#, count: 32))</scene>"#)
  func fan(_ count: Int) throws -> URL {
    try write("fan-\(count).xml", #"<scene version="3.0.0">\#(String(repeating: #"<include filename="fan-middle.xml"/>"#, count: count))</scene>"#)
  }
  let within = MitsubaImporter.maxIncludes / 33
  _ = try MitsubaImporter.Scene(url: try fan(within))
  let beyond = try fan(within + 1)
  requireThrows("more than \(MitsubaImporter.maxIncludes) includes") { _ = try MitsubaImporter.Scene(url: beyond) }

  // The 0.6 names of the archives' properties and a texture's uoffset and voffset (a to_uv translation).
  let archive = try MitsubaImporter.Scene(url: try write("v06-archive.xml", """
    <scene version="0.6.0">
      <texture type="bitmap" id="t"><string name="filterType" value="trilinear"/><string name="wrapMode" value="clamp"/>
        <float name="uoffset" value="0.5"/><float name="voffset" value="0.25"/><float name="uscale" value="2"/></texture>
    </scene>
    """))
  let archiveTexture = archive.root.children[0]
  require(archiveTexture.string("filter_type") == "trilinear" && archiveTexture.string("wrap_mode") == "clamp", "0.6 filterType and wrapMode")
  require(archiveTexture.float("uoffset") == nil && archiveTexture.transform("to_uv") * SIMD4(1, 1, 0, 1) == SIMD4(2.5, 1.25, 0, 1),
    "uoffset and voffset translate after the uv scale")
  print("PASS: Mitsuba XML layer: defaults, variables, references, includes, transforms, hex colours, 0.6 names, depth and size limits")

  // Shapes. tri.ply, tri-binary.ply and tri.serialized are written by Mitsuba (tests/fixtures/mitsuba/README.md);
  // the OBJ files are written here.
  let fixtures = URL(fileURLWithPath: runtimeRepositoryRoot() ?? "/nonexistent").appendingPathComponent("tests/fixtures/mitsuba")
  var shapeScene = try MitsubaImporter.Scene(url: try write("shapes.xml", #"<scene version="3.0.0"/>"#))
  var shapeCount = 0
  func shapeNode(_ xml: String) throws -> MitsubaImporter.Node {
    shapeCount += 1
    return try MitsubaImporter.Scene(url: try write("shape\(shapeCount).xml", #"<scene version="3.0.0">\#(xml)</scene>"#)).root.children[0]
  }
  func meshNode(_ file: String, faceNormals: Bool = false, extra: String = "", id: String? = nil) throws -> MitsubaImporter.Node {
    let inFixtures = FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(file).path)
    let path = inFixtures ? fixtures.appendingPathComponent(file).path : file
    let type = file.hasSuffix(".obj") ? "obj" : file.hasSuffix(".ply") ? "ply" : "serialized"
    return try shapeNode(#"<shape type="\#(type)"\#(id.map { " id=\"\($0)\"" } ?? "")><string name="filename" value="\#(path)"/>"#
      + (faceNormals ? #"<boolean name="face_normals" value="true"/>"# : "") + extra + "</shape>")
  }
  func faceNormal(_ m: MitsubaImporter.Mesh, _ i: Int) -> SIMD3<Float> {
    let t = m.triangles[i]
    let a = m.positions[Int(t.x)]
    return simd_normalize(simd_cross(m.positions[Int(t.y)] - a, m.positions[Int(t.z)] - a))
  }
  func outward(_ m: MitsubaImporter.Mesh, from centre: SIMD3<Float>) -> Bool {
    m.triangles.indices.allSatisfy { i in
      let t = m.triangles[i]
      let middle = (m.positions[Int(t.x)] + m.positions[Int(t.y)] + m.positions[Int(t.z)]) / 3
      return simd_dot(faceNormal(m, i), middle - centre) > 0
    }
  }

  let quad = try MitsubaImporter.mesh(try shapeNode(#"<shape type="rectangle"><transform name="to_world"><scale x="-1"/></transform></shape>"#), index: 0, scene: &shapeScene)!
  require(quad.triangles.count == 2 && faceNormal(quad, 0).z > 0.99, "a mirrored rectangle still faces +z")
  require(quad.normals?.allSatisfy { simd_length($0 - SIMD3(0, 0, 1)) < 1e-6 } == true && quad.uvs?.count == 4, "rectangle normals and uvs")
  let plain = try MitsubaImporter.mesh(try shapeNode(#"<shape type="rectangle"/>"#), index: 0, scene: &shapeScene)!
  require(plain.positions == [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)] && faceNormal(plain, 1).z > 0.99
    && plain.uvs![2] == SIMD2(1, 1), "rectangle spans -1...1 with uv 0...1")
  let disk = try MitsubaImporter.mesh(try shapeNode(#"<shape type="disk"><transform name="to_world"><scale y="-1"/></transform></shape>"#), index: 0, scene: &shapeScene)!
  require(disk.triangles.count == 64 && disk.positions.count == 65 && (0..<64).allSatisfy { faceNormal(disk, $0).z > 0.99 }
    && disk.normals?.allSatisfy { $0 == SIMD3(0, 0, 1) } == true, "a mirrored disk: 64 triangles facing +z")
  let cube = try MitsubaImporter.mesh(try shapeNode(#"<shape type="cube"/>"#), index: 0, scene: &shapeScene)!
  require(cube.triangles.count == 12 && cube.normals == nil && cube.uvs?.count == cube.positions.count
    && cube.positions.allSatisfy { $0.max() == 1 || $0.min() == -1 } && outward(cube, from: .zero), "cube: 12 outward triangles, flat normals")
  let mirroredCube = try MitsubaImporter.mesh(try shapeNode(#"<shape type="cube"><transform name="to_world"><scale x="-2"/></transform></shape>"#), index: 0, scene: &shapeScene)!
  require(outward(mirroredCube, from: .zero), "a mirrored cube stays outward")
  let ball = try MitsubaImporter.mesh(try shapeNode(#"<shape type="sphere"><point name="center" x="1" y="0" z="0"/><float name="radius" value="2"/></shape>"#), index: 0, scene: &shapeScene)!
  require(ball.positions.allSatisfy { abs(simd_length($0 - SIMD3(1, 0, 0)) - 2) < 1e-4 }, "sphere centre and radius")
  require(ball.normals.map { n in zip(n, ball.positions).allSatisfy { simd_length($0 - ($1 - SIMD3(1, 0, 0)) / 2) < 1e-4 } } == true
    && outward(ball, from: SIMD3(1, 0, 0)) && ball.uvs?.count == ball.positions.count, "sphere: smooth outward normals and uvs")
  let moved = try MitsubaImporter.mesh(try shapeNode("""
    <shape type="sphere"><float name="radius" value="2"/><transform name="to_world"><scale x="-1"/><translate y="3"/></transform></shape>
    """), index: 0, scene: &shapeScene)!
  require(moved.positions.allSatisfy { abs(simd_length($0 - SIMD3(0, 3, 0)) - 2) < 1e-4 }
    && outward(moved, from: SIMD3(0, 3, 0)), "a sphere's to_world follows its radius; a mirrored one stays outward")
  let negative = try MitsubaImporter.mesh(try shapeNode(#"<shape type="sphere"><float name="radius" value="-2"/></shape>"#), index: 0, scene: &shapeScene)!
  require(negative.positions.allSatisfy { abs(simd_length($0) - 2) < 1e-4 } && outward(negative, from: .zero),
    "a negative radius is its magnitude, as in Mitsuba, with the normals outward")
  _ = try MitsubaImporter.mesh(try shapeNode(#"<shape type="sphere" id="egg"><transform name="to_world"><scale x="1" y="2" z="1"/></transform></shape>"#), index: 3, scene: &shapeScene)
  _ = try MitsubaImporter.mesh(try shapeNode(#"<shape type="sphere" id="ball"><transform name="to_world"><scale value="2"/><rotate z="1" angle="30"/></transform></shape>"#), index: 4, scene: &shapeScene)
  require(shapeScene.report.contains { $0.hasPrefix("shape 'egg': a sphere under a non-uniform to_world") }
    && !shapeScene.report.contains { $0.hasPrefix("shape 'ball'") }, "a non-uniform to_world on a sphere is reported, a uniform one not")
  _ = try MitsubaImporter.mesh(try shapeNode(#"<shape type="rectangle"><transform name="to_world"><scale x="0"/></transform></shape>"#), index: 7, scene: &shapeScene)
  require(shapeScene.report.contains("shape 'rectangle7' has a singular to_world; skipped"), "the singular to_world line names the shape by type and index")

  _ = try write("tri.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0.5\nvt 1 0.25\nvt 0 0\nvn 0 0 1\nf 1/1/1 2/2/1 3/3/1\n")
  for file in ["tri.obj", "tri.ply", "tri-binary.ply", "tri.serialized"] {
    let m = try MitsubaImporter.mesh(try meshNode(file), index: 0, scene: &shapeScene)!
    require(m.triangles.count == 1 && m.positions.count == 3 && m.uvs?.count == 3, "\(file) reads one triangle")
    require(abs(m.uvs![1].y - (1 - 0.25)) < 1e-6, "\(file): v is flipped")
    require(m.normals == [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)] && m.positions[1] == SIMD3(1, 0, 0), "\(file): positions and normals")
  }
  let second = try MitsubaImporter.mesh(try meshNode("tri.serialized", extra: #"<integer name="shape_index" value="1"/>"#), index: 0, scene: &shapeScene)!
  require(second.positions == [SIMD3(0, 0, 5), SIMD3(1, 0, 5), SIMD3(0, 1, 5)] && second.uvs == nil && second.normals == [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
    "a serialized shape_index selects a double-precision sub-mesh without normals or uvs; smooth normals are computed")
  requireThrows("shape index") {
    _ = try MitsubaImporter.mesh(try meshNode("tri.serialized", extra: #"<integer name="shape_index" value="2"/>"#), index: 0, scene: &shapeScene)
  }
  let placed = try MitsubaImporter.mesh(try meshNode("tri.ply", extra: #"<transform name="to_world"><scale z="2"/><translate x="1"/></transform>"#), index: 0, scene: &shapeScene)!
  require(placed.positions[1] == SIMD3(2, 0, 0) && placed.normals?[0] == SIMD3(0, 0, 1), "to_world applies to positions and normals")
  let flatPly = try MitsubaImporter.mesh(try meshNode("tri-binary.ply", faceNormals: true), index: 0, scene: &shapeScene)!
  require(flatPly.normals == nil && flatPly.uvs?.count == 3, "face_normals drops a file's normals")

  _ = try write("slanted.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nvn 0 1 1\nf 1//1 2//1 3//1\n")
  let slanted = try MitsubaImporter.mesh(try meshNode("slanted.obj", extra: #"<transform name="to_world"><scale z="2"/></transform>"#), index: 0, scene: &shapeScene)!
  let expectedNormal = simd_normalize(SIMD3<Float>(0, 1, 0.5))
  require(slanted.uvs == nil && slanted.normals!.allSatisfy { simd_length($0 - expectedNormal) < 1e-6 }, "normals use the inverse transpose and are renormalized")

  _ = try write("cube-no-normals.obj", """
    v -1 -1 -1
    v 1 -1 -1
    v 1 1 -1
    v -1 1 -1
    v -1 -1 1
    v 1 -1 1
    v 1 1 1
    v -1 1 1
    f 1 4 3 2
    f 5 6 7 8
    f 1 2 6 5
    f 3 4 8 7
    f 1 5 8 4
    f 2 3 7 6
    """)
  let flat = try MitsubaImporter.mesh(try meshNode("cube-no-normals.obj", faceNormals: true), index: 0, scene: &shapeScene)!
  let smooth = try MitsubaImporter.mesh(try meshNode("cube-no-normals.obj"), index: 0, scene: &shapeScene)!
  require(flat.normals == nil && smooth.normals?.count == smooth.positions.count, "face_normals and smooth normals")
  require(smooth.triangles.count == 12 && smooth.positions.count == 8 && outward(smooth, from: .zero), "quads fan-triangulate and weld positions")
  require(zip(smooth.normals!, smooth.positions).allSatisfy { simd_length($0 - simd_normalize($1)) < 1e-5 },
    "a cube's angle-weighted corner normals point along the diagonals")

  _ = try write("polygons.obj", """
    # comment
    v 9 9 9
    v 0 0 0
    v 1 0 0
    v 1 1 0
    v 0 1 0   # trailing comment
    o ignored
    usemtl ignored
    g ignored
    f -4 -3 -2 -1
    """)
  let polygon = try MitsubaImporter.mesh(try meshNode("polygons.obj"), index: 0, scene: &shapeScene)!
  require(polygon.triangles == [SIMD3(0, 1, 2), SIMD3(0, 2, 3)] && polygon.positions.count == 4 && polygon.positions[0] == SIMD3(0, 0, 0),
    "negative indices count back from the vertices read so far; unused vertices are dropped; other statements are ignored")
  _ = try write("seams.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nvt 1 1\nvt 0.5 0.5\nf 1/1 2/2 3/3\nf 2/2 4/4 3/5\n")
  let seams = try MitsubaImporter.mesh(try meshNode("seams.obj"), index: 0, scene: &shapeScene)!
  require(seams.positions.count == 5 && seams.triangles.count == 2 && seams.triangles[1].x == seams.triangles[0].y
    && seams.triangles[1].z != seams.triangles[0].z, "vertices weld per (position, uv, normal) triple")

  _ = try write("bad.obj", "v 0 0 0\nv 1 0 0\nf 1 2 3\n")
  requireThrows("invalid vertex index") { _ = try MitsubaImporter.mesh(try meshNode("bad.obj"), index: 0, scene: &shapeScene) }
  _ = try write("big-endian.ply", "ply\nformat binary_big_endian 1.0\nelement vertex 0\nproperty float x\nend_header\n")
  requireThrows("big-endian") { _ = try MitsubaImporter.mesh(try meshNode("big-endian.ply"), index: 0, scene: &shapeScene) }
  let truncated = try Data(contentsOf: fixtures.appendingPathComponent("tri-binary.ply")).dropLast(20)
  try truncated.write(to: folder.appendingPathComponent("truncated.ply"))
  requireThrows("truncated") { _ = try MitsubaImporter.mesh(try meshNode("truncated.ply"), index: 0, scene: &shapeScene) }
  requireThrows("missing.obj") { _ = try MitsubaImporter.mesh(try meshNode("missing.obj"), index: 0, scene: &shapeScene) }
  requireThrows("shape 'wall'") { _ = try MitsubaImporter.mesh(try meshNode("missing.obj", id: "wall"), index: 0, scene: &shapeScene) }
  requireThrows("shape 'obj0'") { _ = try MitsubaImporter.mesh(try meshNode("missing.obj", id: ""), index: 0, scene: &shapeScene) }
  requireThrows("shape 'floor'") { _ = try MitsubaImporter.mesh(try meshNode("bad.obj", id: "floor"), index: 0, scene: &shapeScene) }
  requireThrows("shape 'ply0'") { _ = try MitsubaImporter.mesh(try meshNode("truncated.ply"), index: 0, scene: &shapeScene) }
  let hair = try shapeNode(#"<shape type="hair"/>"#)
  let skipped = try MitsubaImporter.mesh(hair, index: 0, scene: &shapeScene)
  require(skipped == nil && shapeScene.report.contains { $0.contains("shape hair") }, "unsupported shapes are reported")
  // Malformed and hostile files.
  func fails(_ fragment: String, _ file: String, extra: String = "") {
    requireThrows(fragment) { _ = try MitsubaImporter.mesh(try meshNode(file, extra: extra), index: 0, scene: &shapeScene) }
  }
  let binaryPLY = try Data(contentsOf: fixtures.appendingPathComponent("tri-binary.ply"))
  let headerEnd = binaryPLY.range(of: Data("end_header\n".utf8))!.upperBound
  // The Mitsuba-written binary PLY with its header text edited and its body edited by `body`.
  func ply(_ name: String, header edit: (String) -> String = { $0 }, body: (inout [UInt8]) -> Void = { _ in }) throws {
    var bytes = Array(binaryPLY[headerEnd...])
    body(&bytes)
    try (Data(edit(String(decoding: binaryPLY[..<headerEnd], as: UTF8.self)).utf8) + Data(bytes)).write(to: folder.appendingPathComponent(name))
  }
  try ply("many-vertices.ply", header: { $0.replacingOccurrences(of: "element vertex 3", with: "element vertex 1000") })
  fails("declares more vertices than the file holds", "many-vertices.ply")
  try ply("many-faces.ply", header: { $0.replacingOccurrences(of: "element face 1", with: "element face 5") })
  fails("truncated", "many-faces.ply")
  try ply("unknown-type.ply", header: { $0.replacingOccurrences(of: "property float x", with: "property floot x") })
  fails("unsupported PLY property", "unknown-type.ply")
  try ply("no-end.ply", header: { $0.replacingOccurrences(of: "end_header\n", with: "") })
  fails("header is truncated", "no-end.ply")
  try ply("negative-count.ply", header: { $0.replacingOccurrences(of: "list uchar int", with: "list char int") }, body: { $0[$0.count - 13] = 0xFF })
  fails("malformed", "negative-count.ply")
  try ply("float-count.ply", header: { $0.replacingOccurrences(of: "list uchar int", with: "list float int") })
  fails("integer types", "float-count.ply")
  try ply("float-index.ply", header: { $0.replacingOccurrences(of: "list uchar int", with: "list uchar float") }, body: { $0.replaceSubrange(($0.count - 12)..., with: [UInt8](repeating: 0xFF, count: 12)) })
  fails("integer types", "float-index.ply")
  try ply("inf-normal.ply", body: { $0.replaceSubrange(12..<16, with: [0, 0, 0x80, 0x7F]) })
  fails("invalid vertex data", "inf-normal.ply")
  try ply("nan-uv.ply", body: { $0.replaceSubrange(28..<32, with: [0, 0, 0xC0, 0x7F]) })
  fails("invalid vertex data", "nan-uv.ply")

  for value in ["nan", "inf", "1e30", "-1", "1.5"] {
    fails("shape_index must be a non-negative integer", "tri.serialized", extra: #"<float name="shape_index" value="\#(value)"/>"#)
  }

  _ = try write("index-zero.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 0 1 2\n")
  fails("invalid vertex index 0", "index-zero.obj")
  _ = try write("garbage.obj", "v 0 0 0\nv 1 0 0\nv 0 1 3xyz\nf 1 2 3\n")
  fails("cannot read a number", "garbage.obj")
  _ = try write("lf.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nf 1/1 2/2 3/3\n")
  _ = try write("crlf.obj", "# header\r\nv\t0 0 0 # origin\r\nv 1\t0 0\r\nv 0 1 0\r\n\r\nvt 0 0\r\nvt 1 0\r\nvt 0 1\r\nf\t1/1 2/2 3/3 # face\r\n")
  let lf = try MitsubaImporter.mesh(try meshNode("lf.obj"), index: 0, scene: &shapeScene)!, crlf = try MitsubaImporter.mesh(try meshNode("crlf.obj"), index: 0, scene: &shapeScene)!
  require(lf.positions == crlf.positions && lf.uvs == crlf.uvs && lf.triangles == crlf.triangles && lf.normals == crlf.normals,
    "CRLF line endings, tabs and trailing comments read as the same mesh")
  _ = try write("zero-normal.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nvn 0 0 0\nf 1//1 2//1 3//1\n")
  let zeroNormal = try MitsubaImporter.mesh(try meshNode("zero-normal.obj", id: "zn"), index: 0, scene: &shapeScene)!
  require(shapeScene.report.contains("shape 'zn': invalid normals in zero-normal.obj; smooth normals computed"), "dropped normals are reported")
  require(zeroNormal.normals?.allSatisfy { simd_length($0 - SIMD3(0, 0, 1)) < 1e-6 } == true, "a zero vn gives computed smooth normals")

  // Serialized files built here: a stored (uncompressed) DEFLATE block in a zlib stream.
  func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
  func zlib(_ body: [UInt8]) -> [UInt8] {
    [0x78, 0x01, 0x01] + bytes(UInt16(body.count)) + bytes(~UInt16(body.count)) + body + [0, 0, 0, 0]
  }
  func serialized(vertices: UInt64, faces: UInt64, payload: [UInt8], version: UInt16 = 4, flags: UInt32 = 0x1000) -> [UInt8] {
    bytes(UInt16(0x041C)) + bytes(version) + zlib(bytes(flags) + Array("m\0".utf8) + bytes(vertices) + bytes(faces) + payload)
  }
  let positions = [Float](arrayLiteral: 0, 0, 0, 1, 0, 0, 0, 1, 0).flatMap { bytes($0.bitPattern) }
  let triangle = positions + bytes(UInt32(0)) + bytes(UInt32(1)) + bytes(UInt32(2))
  func serializedFails(_ fragment: String, _ name: String, _ content: [UInt8], extra: String = "") throws {
    try Data(content).write(to: folder.appendingPathComponent(name))
    fails(fragment, name, extra: extra)
  }
  let good = serialized(vertices: 3, faces: 1, payload: triangle)
  try Data(good).write(to: folder.appendingPathComponent("built.serialized"))
  let built = try MitsubaImporter.mesh(try meshNode("built.serialized"), index: 0, scene: &shapeScene)!
  require(built.triangles == [SIMD3(0, 1, 2)], "the test's own serialized builder reads back")
  // Vertex colours (flag 0x8) follow the positions and come before the faces: skipped, the faces read right.
  let vertexColours = [Float](repeating: 0.5, count: 9).flatMap { bytes($0.bitPattern) }
  let quadPositions = [Float](arrayLiteral: 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0).flatMap { bytes($0.bitPattern) }
  let quadColours = [Float](repeating: 0.25, count: 12).flatMap { bytes($0.bitPattern) }
  let quadFaces = [UInt32](arrayLiteral: 0, 1, 2, 0, 2, 3).flatMap { bytes($0) }
  try Data(serialized(vertices: 3, faces: 1, payload: positions + vertexColours + bytes(UInt32(0)) + bytes(UInt32(1)) + bytes(UInt32(2)), flags: 0x1000 | 0x8))
    .write(to: folder.appendingPathComponent("coloured.serialized"))
  try Data(serialized(vertices: 4, faces: 2, payload: quadPositions + quadColours + quadFaces, flags: 0x1000 | 0x8))
    .write(to: folder.appendingPathComponent("coloured-quad.serialized"))
  let coloured = try MitsubaImporter.mesh(try meshNode("coloured.serialized"), index: 0, scene: &shapeScene)!
  let colouredQuad = try MitsubaImporter.mesh(try meshNode("coloured-quad.serialized"), index: 0, scene: &shapeScene)!
  require(coloured.triangles == [SIMD3(0, 1, 2)] && colouredQuad.triangles == [SIMD3(0, 1, 2), SIMD3(0, 2, 3)]
    && colouredQuad.positions[2] == SIMD3(1, 1, 0), "a serialized sub-mesh with vertex colours reads its faces")
  // A binary PLY with uchar colour properties between the position and the normal, and a face property after the list.
  let plyHeader = "ply\nformat binary_little_endian 1.0\nelement vertex 4\nproperty float x\nproperty float y\nproperty float z\n"
    + "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty float nx\nproperty float ny\nproperty float nz\n"
    + "element face 2\nproperty list uchar int vertex_indices\nproperty uchar flags\nend_header\n"
  var plyBody: [UInt8] = []
  for (k, corner) in [SIMD3<Float>(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)].enumerated() {
    plyBody += [corner.x, corner.y, corner.z].flatMap { bytes($0.bitPattern) } + [UInt8(60 * k), 200, 9]
      + [Float](arrayLiteral: 0, 0, 1).flatMap { bytes($0.bitPattern) }
  }
  for face in [[0, 1, 2], [0, 2, 3]] { plyBody += [3] + face.flatMap { bytes(Int32($0)) } + [7] }
  try (Data(plyHeader.utf8) + Data(plyBody)).write(to: folder.appendingPathComponent("coloured.ply"))
  let plyMesh = try MitsubaImporter.mesh(try meshNode("coloured.ply"), index: 0, scene: &shapeScene)!
  require(plyMesh.triangles == [SIMD3(0, 1, 2), SIMD3(0, 2, 3)] && plyMesh.positions[2] == SIMD3(1, 1, 0)
    && plyMesh.normals?.allSatisfy { $0 == SIMD3(0, 0, 1) } == true, "a PLY with uchar colours reads its vertices and faces")
  try serializedFails("outside the importer's limits", "huge-counts.serialized", serialized(vertices: 1 << 40, faces: 1 << 40, payload: triangle))
  try serializedFails("compressed size can hold", "bomb.serialized", serialized(vertices: 5_000_000, faces: 10_000_000, payload: triangle))
  try serializedFails("ends before", "short.serialized", serialized(vertices: 3, faces: 1, payload: Array(triangle.dropLast(4))))
  try serializedFails("more data", "long.serialized", serialized(vertices: 3, faces: 1, payload: triangle + [1, 2, 3, 4, 5, 6, 7, 8]))
  try serializedFails("version 5", "version5.serialized", serialized(vertices: 3, faces: 1, payload: triangle, version: 5))
  try serializedFails("compressed mesh data", "cut.serialized", Array(good.prefix(30)))
  try serializedFails("compressed mesh data", "not-zlib.serialized", Array(good.prefix(4)) + [0xFF, 0xFF, 1, 2, 3])
  // PLY counts that the file cannot hold are rejected before anything is reserved.
  for (kind, header, body) in [
    ("vertices", "ply\nformat binary_little_endian 1.0\nelement vertex 4611686018427387904\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n", [UInt8](repeating: 0, count: 20)),
    ("vertices", "ply\nformat ascii 1.0\nelement vertex 4611686018427387904\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0\n", [UInt8]()),
    ("faces", "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nelement face 4611686018427387904\nproperty list uchar int vertex_indices\nend_header\n", [UInt8](repeating: 0, count: 20)),
  ] {
    try (Data(header.utf8) + Data(body)).write(to: folder.appendingPathComponent("huge-\(kind).ply"))
    fails("declares more \(kind) than the file holds", "huge-\(kind).ply")
  }

  // A serialized sub-mesh is bounded by its own compressed bytes, not by the rest of the file.
  let firstMesh = serialized(vertices: 1, faces: 1_000_000, payload: [UInt8](repeating: 0, count: 12))
  let secondMesh = Array(firstMesh.prefix(4)) + zlib([UInt8](repeating: 0, count: 60000))
  try serializedFails("compressed size can hold", "two-meshes.serialized", firstMesh + secondMesh + bytes(UInt64(0)) + bytes(UInt64(firstMesh.count)) + bytes(UInt32(2)))
  try serializedFails("memory budget", "budget.serialized", serialized(vertices: 3_000_000_000, faces: 1000, payload: triangle, flags: 0x2000 | 0x1 | 0x2))
  // The scene's running totals over its meshes, with limits that three cubes (12 triangles each) fit exactly.
  let cubes = try (0..<3).map { _ in try shapeNode(#"<shape type="cube"/>"#) }
  var totals = shapeScene
  let cubeBytes = try MitsubaImporter.mesh(cubes[0], index: 0, scene: &totals)!.bytes
  let fitting = try MitsubaImporter.loadMeshes(cubes, scene: &totals, progress: nil, triangleLimit: 36, byteLimit: 3 * cubeBytes)
  require(fitting.count == 3 && fitting.allSatisfy { $0 != nil }, "three cubes fit limits of 36 triangles and three cubes' bytes")
  requireThrows("the meshes exceed the 20 triangle limit") {
    _ = try MitsubaImporter.loadMeshes(cubes, scene: &totals, progress: nil, triangleLimit: 20)
  }
  requireThrows("the importer's memory budget") {
    _ = try MitsubaImporter.loadMeshes(cubes, scene: &totals, progress: nil, byteLimit: 2 * cubeBytes)
  }
  // An offset table pointing outside the file or near the end of the integer range.
  let fixture = Array(try Data(contentsOf: fixtures.appendingPathComponent("tri.serialized")))
  for (name, offset) in [("outside", UInt64(0xFFFF)), ("max", UInt64.max), ("int-max", UInt64(Int.max) - 3), ("end", UInt64(fixture.count - 4))] {
    var patched = fixture
    patched.replaceSubrange((patched.count - 12)..<(patched.count - 4), with: bytes(offset))
    try serializedFails("offset table", "offset-\(name).serialized", patched, extra: #"<integer name="shape_index" value="1"/>"#)
  }
  print("PASS: Mitsuba shapes: obj, ply and serialized readers, analytic shapes, normals, winding, texture coordinates")

  // Values taken from Mitsuba: MitsubaTables.swift and plastic-ratios.json are written by
  // scripts/generate_mitsuba_tables.py under Mitsuba 3.9.1, which the tests do not need.
  func nodeWith(_ name: String, _ value: String, tag: String = "string") throws -> MitsubaImporter.Node {
    try shapeNode(#"<bsdf type="dielectric"><\#(tag) name="\#(name)" value="\#(value)"/></bsdf>"#)
  }
  func etaKNode(eta: [Float], k: [Float]) throws -> MitsubaImporter.Node {
    func text(_ v: [Float]) -> String { v.map { "\($0)" }.joined(separator: " ") }
    return try shapeNode(#"<bsdf type="conductor"><rgb name="eta" value="\#(text(eta))"/><rgb name="k" value="\#(text(k))"/></bsdf>"#)
  }
  struct PlasticRow: Decodable, CustomStringConvertible {
    let eta: Float, alpha: Float?, distribution: String?, nonlinear: Bool, rho: Float, ratio: Float
    var ggx: Bool { distribution == "ggx" }
    var description: String { "eta \(eta) alpha \(alpha.map { "\($0)" } ?? "smooth") \(distribution ?? "") nonlinear \(nonlinear) rho \(rho)" }
  }
  struct PlasticFixture: Decodable { let mitsuba: String, rows: [PlasticRow] }
  func plasticFixture() throws -> PlasticFixture {
    try JSONDecoder().decode(PlasticFixture.self, from: Data(contentsOf: fixtures.appendingPathComponent("plastic-ratios.json")))
  }

  let ratios = try plasticFixture()
  require(MitsubaTables.mitsubaVersion == "3.9.1" && ratios.mitsuba == "3.9.1", "the tables and the fixture come from Mitsuba 3.9.1")
  let bk7 = try MitsubaImporter.ior(nodeWith("int_ior", "bk7"), "int_ior", default: 1)
  require(abs(bk7 - 1.5046) < 1e-4, "named IOR")
  let water = try MitsubaImporter.ior(nodeWith("ext_ior", "Water"), "ext_ior", default: 1)
  require(abs(water - 1.333) < 1e-4, "IOR names ignore case, as Mitsuba's")
  let number = try MitsubaImporter.ior(nodeWith("int_ior", "1.7", tag: "float"), "int_ior", default: 1)
  let absent = try MitsubaImporter.ior(nodeWith("int_ior", "bk7"), "ext_ior", default: 1.000277)
  require(number == 1.7 && absent == 1.000277, "a number, or the default when absent")
  requireThrows("unknown IOR 'unobtainium'") { _ = try MitsubaImporter.ior(nodeWith("int_ior", "unobtainium"), "int_ior", default: 1) }
  require(MitsubaTables.ior.count == 23 && ["Cu", "Au", "Ag", "Al", "none"].allSatisfy { MitsubaTables.conductors[$0] != nil },
    "every IOR name and the common conductors")
  require(MitsubaTables.conductors.values.allSatisfy { simd_reduce_min($0.f0) >= 0 && simd_reduce_max($0.f0) <= 1
    && simd_reduce_min($0.tint) >= 0 && simd_reduce_max($0.tint) <= 1 }, "every conductor's F0 and tint are reflectances")
  let gold = try MitsubaImporter.conductor(nodeWith("material", "Au"))
  require(gold.f0.x > gold.f0.z && simd_reduce_max(gold.tint) <= 1, "gold is warm and its tint is a reflectance")
  let mirror = try MitsubaImporter.conductor(nodeWith("material", "none"))
  require(mirror.f0 == SIMD3(1, 1, 1) && mirror.tint == SIMD3(1, 1, 1), "the none conductor is a perfect mirror")
  let unnamed = try MitsubaImporter.conductor(nodeWith("int_ior", "bk7"))
  require(unnamed.f0 == SIMD3(1, 1, 1) && unnamed.tint == SIMD3(1, 1, 1), "no material and no eta: none, as Mitsuba's default")
  // Mitsuba 3.9.1 with k (3.9, 2.4, 2.2) and no eta (eta 0): F0 (1, 1, 1) and tint (1, 1, 1), measured on the package.
  let kOnly = try MitsubaImporter.conductor(nodeWith("k", "3.9 2.4 2.2", tag: "rgb"))
  require(kOnly.f0 == SIMD3(1, 1, 1) && kOnly.tint == SIMD3(1, 1, 1), "k without eta: eta 0, as Mitsuba's")
  requireThrows("unknown conductor 'Kryptonite'") { _ = try MitsubaImporter.conductor(nodeWith("material", "Kryptonite")) }
  let eta = SIMD3<Float>(0.2, 0.9, 1.1), k = SIMD3<Float>(3.9, 2.4, 2.2)
  let explicit = try MitsubaImporter.conductor(etaKNode(eta: [eta.x, eta.y, eta.z], k: [k.x, k.y, k.z]))
  let expectedF0 = ((eta - 1) * (eta - 1) + k * k) / ((eta + 1) * (eta + 1) + k * k)
  require(simd_length(explicit.f0 - expectedF0) < 1e-4, "explicit eta, k through the Fresnel formula")
  // Mitsuba 3.9.1's smooth conductor at these eta and k: its reflectance at mu = 1/7 over the Schlick curve from F0.
  require(simd_length(explicit.tint - SIMD3(0.978395, 0.974457, 0.977413)) < 1e-4, "explicit eta, k: the 82-degree tint")
  requireThrows("not both") {
    _ = try MitsubaImporter.conductor(shapeNode(#"<bsdf type="conductor"><string name="material" value="Au"/><float name="eta" value="1"/></bsdf>"#))
  }
  var worst = (error: Float(0), row: "")
  for row in ratios.rows {
    let r = MitsubaImporter.plasticRatio(eta: row.eta, alpha: row.alpha, ggx: row.ggx, nonlinear: row.nonlinear, rho: row.rho)
    require(abs(r / row.ratio - 1) < 1e-3, "plastic ratio within 0.1% of Mitsuba at \(row)")
    if abs(r / row.ratio - 1) > worst.error { worst = (abs(r / row.ratio - 1), "\(row)") }
  }
  print("Mitsuba plastic ratios: largest relative error \(worst.error) at \(worst.row)")
  let neutral = [MitsubaImporter.plasticRatio(eta: .nan, alpha: 0.1, ggx: true, nonlinear: false, rho: 0.5),
                 MitsubaImporter.plasticRatio(eta: 1.5, alpha: .nan, ggx: true, nonlinear: false, rho: 0.5),
                 MitsubaImporter.plasticRatio(eta: 0, alpha: nil, ggx: false, nonlinear: false, rho: 0.5),
                 MitsubaImporter.plasticRatio(eta: -1.5, alpha: 0.1, ggx: false, nonlinear: false, rho: 0.5),
                 MitsubaImporter.plasticRatio(eta: .infinity, alpha: nil, ggx: false, nonlinear: false, rho: 0.5)]
  require(neutral.allSatisfy { $0 == 1 }, "a non-finite or non-positive eta, or a non-finite alpha, gives the neutral ratio 1")
  let clamped = MitsubaImporter.plasticRatio(eta: 1.5, alpha: 0, ggx: true, nonlinear: false, rho: 0.5)
  require(clamped.isFinite && clamped > 0 && clamped == MitsubaImporter.plasticRatio(eta: 1.5, alpha: -1, ggx: true, nonlinear: false, rho: 0.5)
    && clamped == MitsubaImporter.plasticRatio(eta: 1.5, alpha: 1e-4, ggx: true, nonlinear: false, rho: 0.5), "alpha 0 and below clamp to 1e-4")
  print("PASS: Mitsuba values: named IORs and conductors, conductor Fresnel, plastic internal scattering")

  // Materials: each document is compiled by the app's MaterialX compiler and its OpenPBR inputs read from the
  // compiled program, as Fix_gltf.swift reads its imported materials.
  let bakes = folder.appendingPathComponent("bakes", isDirectory: true)
  try FileManager.default.createDirectory(at: bakes, withIntermediateDirectories: true)
  var materials = try MitsubaImporter.Scene(url: try write("materials.xml", #"<scene version="3.0.0"/>"#))
  func bsdf(_ xml: String, version: String = "3.0.0") throws -> MitsubaImporter.Node {
    shapeCount += 1
    return try MitsubaImporter.Scene(url: try write("bsdf\(shapeCount).xml", #"<scene version="\#(version)">\#(xml)</scene>"#)).root.children[0]
  }
  func document(_ node: MitsubaImporter.Node?, emission: SIMD3<Float>? = nil, interior: MitsubaImporter.Node? = nil,
                name: String = "m", mesh: MitsubaImporter.Mesh? = nil) throws -> String {
    try MitsubaImporter.material(bsdf: node, emission: emission, interior: interior, name: name, scene: &materials, folder: bakes, mesh: mesh)
  }
  func compiled(_ text: String) throws -> MaterialXProgram {
    let result = try MaterialXImporter.read(Data(text.utf8), baseURL: bakes, source: "mitsuba")
    guard let program = result.materials.first else { throw MaterialLibrary.error("the document does not compile: \(result.report)") }
    return program
  }
  func program(_ xml: String, emission: SIMD3<Float>? = nil, interior: String? = nil, name: String = "m") throws -> MaterialXProgram {
    try compiled(document(try bsdf(xml), emission: emission, interior: try interior.map { try bsdf($0) }, name: name))
  }
  // A surface input's constant (unauthored inputs read their OpenPBR default); nil when connected to a node.
  func input(_ p: MaterialXProgram, _ name: String) -> SIMD3<Float>? {
    p.parameters.first { $0.name.hasSuffix("/" + name) }.flatMap { $0.defaultValue }.map { SIMD3($0.x, $0.y, $0.z) }
  }
  func near(_ a: SIMD3<Float>?, _ b: SIMD3<Float>, _ tolerance: Float = 1e-5) -> Bool { a.map { simd_length($0 - b) < tolerance } ?? false }
  func near(_ a: SIMD3<Float>?, _ b: Float, _ tolerance: Float = 1e-5) -> Bool { a.map { abs($0.x - b) < tolerance } ?? false }
  func image(_ data: Data) -> CGImage? { CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
  func texture(_ name: String, _ texel: (Int, Int) -> (UInt8, UInt8, UInt8), size: Int = 4) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 3,
      hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 3 * size, bitsPerPixel: 24)!
    for y in 0..<size { for x in 0..<size { let c = texel(x, y); rep.bitmapData![3 * (y * size + x)] = c.0; rep.bitmapData![3 * (y * size + x) + 1] = c.1; rep.bitmapData![3 * (y * size + x) + 2] = c.2 } }
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
  }

  let diffuse = try program(#"<bsdf type="diffuse"><rgb name="reflectance" value="0.2, 0.4, 0.6"/></bsdf>"#)
  require(near(input(diffuse, "base_color"), SIMD3(0.2, 0.4, 0.6)) && near(input(diffuse, "specular_weight"), 0), "diffuse: base_color, specular_weight 0")
  let copper = try program("""
    <bsdf type="roughconductor"><string name="material" value="Cu"/><float name="alpha" value="0.25"/>
      <rgb name="specular_reflectance" value="0.5"/></bsdf>
    """)
  let cu = MitsubaTables.conductors["Cu"]!
  require(near(input(copper, "base_metalness"), 1) && near(input(copper, "specular_roughness"), 0.5) && near(input(copper, "specular_weight"), 0.5)
    && near(input(copper, "base_color"), cu.f0) && copper.specularColor.map { simd_length($0 - cu.tint) < 1e-5 } == true,
    "roughconductor: metalness 1, roughness sqrt(alpha), specular_reflectance as specular_weight, F0 and the edge tint")
  let waterGlass = try program(#"<bsdf type="dielectric"><string name="int_ior" value="water"/></bsdf>"#)
  require(near(input(waterGlass, "transmission_weight"), 1) && near(input(waterGlass, "specular_ior"), 1.333 / 1.000277), "dielectric: transmission and IOR ratio")
  let screen = try program(#"<bsdf type="dielectric"><string name="int_ior" value="water"/><rgb name="specular_transmittance" value="0"/></bsdf>"#)
  require(near(input(screen, "base_color"), SIMD3(repeating: 0)) && near(input(screen, "transmission_weight"), 0), "dielectric without transmittance: a black reflector")
  let pane = try program(#"<bsdf type="thindielectric"/>"#)
  require(pane.thinWalled == true && near(input(pane, "transmission_weight"), 1), "thindielectric: thin-walled transmission")
  let plastic = try program(#"<bsdf type="plastic"><rgb name="diffuse_reflectance" value="0.5"/><boolean name="nonlinear" value="true"/></bsdf>"#)
  let ratio = MitsubaImporter.plasticRatio(eta: 1.49 / 1.000277, alpha: nil, ggx: false, nonlinear: true, rho: 0.5)
  require(near(input(plastic, "base_color"), SIMD3(repeating: 0.5 * ratio)) && near(input(plastic, "specular_ior"), 1.49 / 1.000277)
    && near(input(plastic, "specular_roughness"), 0), "plastic: base_color rho x the internal-scattering ratio")
  let masked = try program(#"<bsdf type="mask"><float name="opacity" value="0.61"/><bsdf type="diffuse"/></bsdf>"#)
  require(masked.opacity != nil && near(input(masked, "geometry_opacity"), 0.61) && near(input(masked, "base_color"), SIMD3(repeating: 0.5)),
    "mask: geometry_opacity over the inner BSDF")
  let inner = #"<bsdf type="diffuse"><rgb name="reflectance" value="0.3"/></bsdf>"#
  let twosided = try document(bsdf("<bsdf type=\"twosided\">\(inner)</bsdf>")), single = try document(bsdf(inner))
  require(twosided == single, "twosided: its inner BSDF's inputs")
  let checker = try program(#"<bsdf type="diffuse"><texture type="checkerboard" name="reflectance"/></bsdf>"#)
  let baked = try FileManager.default.contentsOfDirectory(atPath: bakes.path).filter { $0.contains("checker") }
  require(checker.images.count == 1 && image(checker.images[0].data).map { $0.width == 256 && $0.height == 256 } == true && baked.count == 1
    && input(checker, "base_color") == nil, "checkerboard: a 256 x 256 PNG baked into the folder")
  let lamp = try compiled(document(nil, emission: SIMD3(repeating: 5)))
  require(lamp.emission != nil && near(input(lamp, "emission_color").map { $0 * (input(lamp, "emission_luminance")?.x ?? 0) }, SIMD3(repeating: 5))
    && near(input(lamp, "base_color"), SIMD3(repeating: 0)), "an emitter without a BSDF: its radiance as emission over a black surface")
  let bare = try compiled(document(nil))
  require(near(input(bare, "base_color"), SIMD3(repeating: 0.5)) && bare.emission == nil, "no BSDF and no emitter: grey 0.5")
  let medium = #"<medium type="homogeneous" name="interior"><rgb name="albedo" value="0"/><rgb name="sigma_t" value="0.5, 0.2, 0.4"/></medium>"#
  let tinted = try program(#"<bsdf type="dielectric"/>"#, interior: medium)
  require(tinted.medium?.w == 1 && tinted.transmissionColor.map { simd_length($0 - SIMD3(0.6065, 0.8187, 0.6703)) < 1e-4 } == true,
    "an absorbing interior: transmission_color exp(-sigma_t) at transmission_depth 1")
  let oldMedium = #"<medium type="homogeneous" name="interior"><rgb name="sigmaS" value="0"/><rgb name="sigmaA" value="0.5, 0.2, 0.4"/></medium>"#
  let oldTinted = try compiled(document(try bsdf(#"<bsdf type="dielectric"/>"#), interior: try bsdf(oldMedium, version: "0.6.0")))
  require(oldTinted.transmissionColor.map { simd_length($0 - SIMD3(0.6065, 0.8187, 0.6703)) < 1e-4 } == true, "a 0.6 medium with sigma_s 0 absorbs by sigma_a")
  let foggy = try program(#"<bsdf type="dielectric"/>"#, interior: #"<medium type="homogeneous" name="interior"><rgb name="albedo" value="0.5"/></medium>"#, name: "fog")
  let opaque = try program(#"<bsdf type="diffuse"/>"#, interior: medium, name: "wall")
  require(foggy.medium == nil && opaque.medium == nil && materials.report.contains { $0.hasPrefix("fog: interior medium") }
    && materials.report.contains { $0.hasPrefix("wall: interior medium") }, "a scattering medium, or one behind an opaque BSDF, is reported and ignored")
  let fur = try program(#"<bsdf type="hair"/>"#, name: "fur")
  require(near(input(fur, "base_color"), SIMD3(repeating: 0.5)) && materials.report.contains { $0.contains("BSDF hair unsupported") },
    "an unsupported BSDF: grey diffuse and a report line")

  let defaultMirror = try program(#"<bsdf type="conductor"/>"#)
  require(near(input(defaultMirror, "base_color"), SIMD3(repeating: 1)) && near(input(defaultMirror, "base_metalness"), 1) && defaultMirror.specularColor == nil,
    "a conductor without a material: Mitsuba's default, a perfect mirror")
  let kOnlyNode = try bsdf(#"<bsdf type="conductor"><rgb name="k" value="3.9, 2.4, 2.2"/></bsdf>"#)
  let kOnlyProgram = try compiled(document(kOnlyNode)), kOnlyF0 = try MitsubaImporter.conductor(kOnlyNode).f0
  require(near(input(kOnlyProgram, "base_color"), kOnlyF0) && near(input(kOnlyProgram, "base_metalness"), 1), "a k-only conductor: eta 0, as Mitsuba's")
  let invalid = try program(#"<bsdf type="roughplastic"><float name="alpha" value="nan"/><rgb name="diffuse_reflectance" value="0.5"/></bsdf>"#, name: "glossy")
  require(near(input(invalid, "base_color"), SIMD3(repeating: 0.5)) && materials.report.contains { $0.hasPrefix("glossy: alpha") },
    "a non-finite alpha: reported, with the neutral plastic ratio")
  let oldPlastic = try compiled(document(try bsdf(#"<bsdf type="plastic"><srgb name="diffuseReflectance" value="0.5, 0.5, 0.5"/></bsdf>"#, version: "0.6.0")))
  let linear = srgbToLinear(0.5)
  require(near(input(oldPlastic, "base_color"), SIMD3(repeating: linear * MitsubaImporter.plasticRatio(eta: 1.49 / 1.000277, alpha: nil, ggx: false, nonlinear: false, rho: linear))),
    "a 0.6 srgb colour on a plastic is linearized")
  _ = try program(#"<bsdf type="plastic"><srgb name="diffuse_reflectance" value="0.5, 0.5, 0.5"/></bsdf>"#, name: "v3")
  require(materials.report.contains("v3: srgb colour on plastic is not read; default used"), "an srgb colour in a Mitsuba 3 file is reported")
  try texture("wood.png") { x, y in (UInt8(x * 60), UInt8(y * 60), 128) }
  let tiled = try document(bsdf("""
    <bsdf type="diffuse"><texture type="bitmap" name="reflectance"><string name="filename" value="wood.png"/>
      <transform name="to_uv"><scale x="2" y="3"/></transform></texture></bsdf>
    """))
  let tiledProgram = try compiled(tiled)
  require(tiledProgram.images.count == 1 && tiledProgram.images[0].srgb && tiled.contains(#"type="vector2" value="2.0, 3.0""#),
    "a textured diffuse: an sRGB image sampled at texcoord x the to_uv scale")
  requireThrows("material 'shelf'") {
    _ = try document(bsdf(#"<bsdf type="diffuse"><texture type="bitmap" name="reflectance"><string name="filename" value="lost.png"/></texture></bsdf>"#), name: "shelf")
  }
  requireThrows("lost.png") {
    _ = try document(bsdf(#"<bsdf type="diffuse"><texture type="bitmap" name="reflectance"><string name="filename" value="lost.png"/></texture></bsdf>"#), name: "shelf")
  }
  let tiles = try compiled(document(bsdf("""
    <bsdf type="roughplastic"><boolean name="nonlinear" value="true"/>
      <texture type="bitmap" name="diffuse_reflectance"><string name="filename" value="wood.png"/></texture></bsdf>
    """), name: "tiles"))
  require(tiles.images.count == 1 && tiles.images[0].name.hasSuffix("-plastic.png") && materials.report.contains { $0.hasPrefix("tiles: nonlinear plastic texture baked") },
    "a textured nonlinear plastic is baked per texel")
  try texture("bumps.png") { x, _ in (UInt8(x * 80), UInt8(x * 80), UInt8(x * 80)) }
  let bumpNode = try bsdf(#"<bsdf type="bumpmap"><texture type="bitmap" name="map"><string name="filename" value="bumps.png"/></texture><bsdf type="diffuse"/></bsdf>"#)
  let bumped = try compiled(document(bumpNode, name: "bumpy", mesh: plain))
  require(bumped.images.count == 1 && materials.report.contains { $0.hasPrefix("bumpy: bump map converted to a normal map (UV stretch 2 x 2)") },
    "a bump map becomes a tangent-space normal map from the mesh's UV stretch")
  _ = try compiled(document(bumpNode, name: "flat"))
  require(materials.report.contains("flat: bump map dropped (its mesh has no UVs)"), "a bump map without a mesh's UVs is dropped and reported")
  print("PASS: Mitsuba materials: BSDFs, textures, emitters and interior media as OpenPBR MaterialX")
}
try fixMitsubaChecks()

// Mitsuba scene assembly (MitsubaImporter.load): shapes as assets and nodes, shared materials, the sensor as the saved
// view "Mitsuba: camera" (field of view from fov, fov_axis and the film), the film size as the render size, max_depth
// as the path depth, envmap and constant emitters as the environment, unsupported plugins in the report, shapes reversed
// for a dielectric (wrapped or not) with an IOR ratio below 1 and their emitters and media, Open Scene File, and on the
// GPU an emitter that lights the floor in absolute units.
@MainActor func fixMitsubaSceneChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("mitsuba-scene", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  var written = 0
  func write(_ xml: String, name: String? = nil) throws -> URL {
    written += 1
    let url = folder.appendingPathComponent(name ?? "scene\(written).xml")
    try xml.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
  func load(_ xml: String) throws -> USDImportResult { try MitsubaImporter.load(try write(xml), into: ProjectDocument()) }
  try "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".write(to: folder.appendingPathComponent("tri.obj"), atomically: true, encoding: .utf8)
  // A uniform 8 x 4 Radiance HDR sky of radiance 1 (RGBE 128 128 128 129).
  var sky = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 4 +X 8\n".utf8)
  for _ in 0..<32 { sky.append(contentsOf: [128, 128, 128, 129]) }
  try sky.write(to: folder.appendingPathComponent("sky.hdr"))

  func sensor(_ inner: String = #"<float name="fov" value="90"/><string name="fov_axis" value="x"/>"#, type: String = "perspective",
              width: Int = 1280, height: Int = 720) -> String {
    """
    <sensor type="\(type)">\(inner)
      <transform name="to_world"><lookat origin="0, 2, 6" target="0, 0, 0" up="0, 1, 0"/></transform>
      <film type="hdrfilm"><integer name="width" value="\(width)"/><integer name="height" value="\(height)"/></film>
    </sensor>
    """
  }
  let floor = #"<shape type="rectangle" id="floor"><transform name="to_world"><scale value="5"/><rotate x="1" angle="-90"/></transform><bsdf type="diffuse"/></shape>"#
  let lamp = #"<shape type="sphere" id="lamp"><point name="center" x="0" y="1" z="0"/><float name="radius" value="0.5"/><emitter type="area"><rgb name="radiance" value="10"/></emitter></shape>"#
  let envmap = #"<emitter type="envmap"><string name="filename" value="sky.hdr"/><float name="scale" value="2"/><transform name="to_world"><rotate y="1" angle="180"/></transform></emitter>"#
  func synthetic(sensor camera: String? = sensor(), lamp light: String = lamp, environment: String = envmap) -> String {
    """
    <scene version="3.0.0">
      <integrator type="path"><integer name="max_depth" value="7"/></integrator>
      \(camera ?? "")
      <bsdf type="roughplastic" id="shiny"><string name="distribution" value="ggx"/><float name="alpha" value="0.2"/></bsdf>
      \(floor)
      <shape type="obj" id="tri"><string name="filename" value="tri.obj"/><transform name="to_world"><translate x="3"/></transform><ref id="shiny"/></shape>
      \(light)
      \(environment)
      <emitter type="point"><point name="position" x="0" y="3" z="0"/></emitter>
    </scene>
    """
  }

  // The synthetic scene: three shapes, the camera, render size, depth, environment and report.
  let imported = try load(synthetic())
  let p = imported.document
  let view = p.views["Mitsuba: camera"]
  require(p.graph?.assets.count == 3 && p.graph?.nodes.filter { $0.mesh != nil }.count == 3
    && p.graph?.assets.map(\.name) == ["floor", "tri", "lamp"], "one asset and one node per shape, named by id")
  require(view.map { abs($0.fov - 58.7155) < 0.01 } == true && p.camera.fov == view?.fov && p.camera.target == view?.target,
    "the sensor is the active view 'Mitsuba: camera' with a vertical field of view of 58.72 degrees (\(String(describing: view?.fov)))")
  require(p.options.outputWidth == 1280 && p.options.outputHeight == 720 && p.options.depth == 6,
    "the film sets the render size and max_depth 7 the path depth 6")
  require(abs(p.options.environmentRotation - 90) < 1e-3 && p.options.environmentIntensity == 2 && p.environmentName == "sky.hdr"
    && p.environmentData == sky, "the envmap is the environment: file, scale and its turn about +y (\(p.options.environmentRotation))")
  let oneSided = "BSDFs without twosided are one-sided in Mitsuba (black from the back); rendered two-sided"
  require(imported.report == [oneSided, "emitter point unsupported; skipped"] && p.importReport == imported.report,
    "the report lists the one-sided BSDFs once and the skipped point emitter, and nothing about the supported plugins (\(imported.report))")
  let eye = p.camera.target + p.camera.distance * SIMD3(cos(p.camera.pitch) * sin(p.camera.yaw), sin(p.camera.pitch), -cos(p.camera.pitch) * cos(p.camera.yaw))
  require(simd_length(eye - SIMD3(0, 2, 6)) < 1e-3, "the camera sits at the sensor's origin (\(eye))")

  // The envmap's turn: the app's rotation is the turn about +y minus 90 degrees (the image centre faces +z in Mitsuba).
  for (angle, expected) in [(Float(0), Float(-90)), (90, 0), (-90, 180)] {
    let turned = try load(synthetic(environment: #"<emitter type="envmap"><string name="filename" value="sky.hdr"/><transform name="to_world"><rotate y="1" angle="\#(angle)"/></transform></emitter>"#)).document
    let difference = (turned.options.environmentRotation - expected).truncatingRemainder(dividingBy: 360)
    require(min(abs(difference), 360 - abs(difference)) < 1e-3, "an envmap turned \(angle) degrees: rotation \(expected) (\(turned.options.environmentRotation))")
  }
  let tilted = try load(synthetic(environment: #"<emitter type="envmap"><string name="filename" value="sky.hdr"/><transform name="to_world"><rotate x="1" angle="30"/></transform></emitter>"#))
  require(tilted.report.contains { $0.hasPrefix("envmap: to_world is not a turn about +y") }, "a tilted envmap is reported (\(tilted.report))")
  let constant = try load(synthetic(environment: #"<emitter type="constant"><rgb name="radiance" value="0.5, 1, 2"/></emitter>"#)).document
  require(constant.environmentData != nil && constant.options.environmentIntensity == 1 && constant.environmentName.hasSuffix(".hdr"),
    "a constant emitter is a uniform environment")

  // No sensor: the default camera and a report line.
  let blind = try load(synthetic(sensor: nil))
  require(blind.document.views.isEmpty && blind.report.contains { $0.hasPrefix("no supported sensor") }, "no sensor is reported (\(blind.report))")
  // Field of view axes, the default focal length, and a thin lens.
  func verticalFOV(_ inner: String, width: Int = 1280, height: Int = 720) throws -> Float {
    try load(synthetic(sensor: sensor(inner, width: width, height: height))).document.views["Mitsuba: camera"]?.fov ?? 0
  }
  let axisY = try verticalFOV(#"<float name="fov" value="90"/><string name="fov_axis" value="y"/>"#)
  let smaller = try verticalFOV(#"<float name="fov" value="90"/><string name="fov_axis" value="smaller"/>"#)
  let larger = try verticalFOV(#"<float name="fov" value="90"/><string name="fov_axis" value="larger"/>"#, width: 720, height: 1280)
  let diagonal = try verticalFOV(#"<float name="fov" value="90"/><string name="fov_axis" value="diagonal"/>"#)
  let focal = try verticalFOV("", width: 768, height: 576)
  require(abs(axisY - 90) < 0.01 && abs(smaller - 90) < 0.01 && abs(larger - 90) < 0.01 && abs(diagonal - 52.2338) < 0.01
    && abs(focal - 29.1054) < 0.01, "fov_axis y, smaller, larger and diagonal, and the 50 mm default (\([axisY, smaller, larger, diagonal, focal]))")
  let lens = try load(synthetic(sensor: sensor(#"<float name="fov" value="40"/><float name="aperture_radius" value="0.1"/><float name="focus_distance" value="3"/>"#, type: "thinlens"))).document
  require(lens.views["Mitsuba: camera"] != nil && abs(lens.options.aperture - 0.1) < 1e-6 && abs(lens.options.focusDistance - 3) < 1e-5,
    "a thinlens sensor sets the aperture radius and focus distance")
  // Depth: max_depth -1 and an absent max_depth are the app's deepest path, 64.
  let unbounded = try load(synthetic().replacingOccurrences(of: #"value="7""#, with: #"value="-1""#)).document
  let absent = try load(synthetic().replacingOccurrences(of: #"<integrator type="path"><integer name="max_depth" value="7"/></integrator>"#, with: "")).document
  require(unbounded.options.depth == 64 && absent.options.depth == 64, "max_depth -1 or absent gives depth 64")
  // Hostile values: a max_depth beyond Int's range or not finite, an envmap scale that is not a number.
  let huge = try load(synthetic().replacingOccurrences(of: #"value="7""#, with: #"value="1e30""#))
  let infinite = try load(synthetic().replacingOccurrences(of: #"value="7""#, with: #"value="inf""#))
  require(huge.document.options.depth == 64 && huge.report.contains("max_depth 1e+30 rendered at path depth 64, the app's largest")
    && infinite.document.options.depth == 64 && infinite.report.contains("max_depth inf is not a finite number; path depth 64 used"),
    "max_depth 1e30 and inf give depth 64 with a report line (\(huge.report), \(infinite.report))")
  let nanScale = try load(synthetic(environment: envmap.replacingOccurrences(of: #"value="2""#, with: #"value="nan""#)))
  require(nanScale.document.options.environmentIntensity == 0 && nanScale.report.contains("envmap scale is not a number; 0 used"),
    "an envmap scale that is not a number is 0, and the report says so (\(nanScale.report))")
  // One-sided BSDFs: a twosided anywhere in the wrapper chain, or a dielectric or principledthin leaf, is two-sided in
  // Mitsuba too.
  let twoSided = try load("""
    <scene version="3.0.0">
      <shape type="rectangle"><bsdf type="mask"><bsdf type="twosided"><bsdf type="diffuse"/></bsdf></bsdf></shape>
      <shape type="rectangle"><bsdf type="bumpmap"><texture type="checkerboard"/><bsdf type="roughdielectric"/></bsdf></shape>
      <shape type="rectangle"><bsdf type="principledthin"/></shape>
      <shape type="rectangle"><emitter type="area"/></shape>
    </scene>
    """)
  require(!twoSided.report.contains(oneSided), "twosided wrappers and two-sided leaves are not reported (\(twoSided.report))")
  let unsided = try load("""
    <scene version="3.0.0">
      <shape type="rectangle"><bsdf type="mask"><bsdf type="conductor"/></bsdf></shape>
      <shape type="rectangle"><bsdf type="plastic"/></shape>
    </scene>
    """)
  require(unsided.report.filter { $0 == oneSided }.count == 1, "one-sided BSDFs give one scene-level line (\(unsided.report))")
  // A shape without a BSDF has Mitsuba's default diffuse, also one-sided; an emitter's black default is not reported.
  let bare = try load(#"<scene version="3.0.0"><shape type="rectangle"/></scene>"#)
  require(bare.report.contains(oneSided), "a shape without a BSDF is reported one-sided (\(bare.report))")

  // Materials: shared by BSDF id and emission.
  let shared = try load("""
    <scene version="3.0.0">
      <bsdf type="diffuse" id="paint"/>
      <shape type="rectangle" id="a"><ref id="paint"/></shape>
      <shape type="rectangle" id="b"><ref id="paint"/></shape>
      <shape type="rectangle" id="c"><ref id="paint"/><emitter type="area"><rgb name="radiance" value="1"/></emitter></shape>
      <shape type="rectangle" id="d"><bsdf type="diffuse"/></shape>
    </scene>
    """).document
  let bindings = shared.graph?.nodes.filter { $0.mesh != nil }.map { $0.bindings.first } ?? []
  require(bindings.count == 4 && bindings[0] == bindings[1] && bindings[2] != bindings[0] && bindings[3] != bindings[0]
    && shared.graph?.materials.count == 3, "shapes that reference one BSDF share a material; an emissive one gets its own")

  // One BSDF id with two emitter radiances or two interiors: the materials get distinct names.
  let lamps = try load("""
    <scene version="3.0.0">
      <bsdf type="diffuse" id="paint"/>
      <shape type="rectangle" id="a"><ref id="paint"/><emitter type="area"><rgb name="radiance" value="1"/></emitter></shape>
      <shape type="rectangle" id="b"><ref id="paint"/><emitter type="area"><rgb name="radiance" value="2"/></emitter></shape>
      <shape type="rectangle" id="c"><ref id="paint"/><emitter type="area"><rgb name="radiance" value="3"/></emitter></shape>
      <shape type="rectangle" id="d"><ref id="paint"/></shape>
    </scene>
    """).document
  let litNames = lamps.graph?.materials.map(\.name) ?? []
  require(litNames == ["paint_emitter", "paint_emitter 2", "paint_emitter 3", "paint"], "materials of one BSDF id with different radiances: suffixed names (\(litNames))")
  let murky = try load("""
    <scene version="3.0.0">
      <bsdf type="dielectric" id="glass"/>
      <medium type="homogeneous" id="fog"><rgb name="albedo" value="0"/><rgb name="sigma_t" value="1"/></medium>
      <medium type="homogeneous" id="soup"><rgb name="albedo" value="0"/><rgb name="sigma_t" value="2"/></medium>
      <shape type="rectangle" id="a"><ref id="glass"/><ref name="interior" id="fog"/></shape>
      <shape type="rectangle" id="b"><ref id="glass"/><ref name="interior" id="soup"/></shape>
    </scene>
    """).document
  require(murky.graph?.materials.map(\.name) == ["glass", "glass 2"], "materials of one BSDF id with different interiors: suffixed names (\(String(describing: murky.graph?.materials.map(\.name))))")

  // flip_normals reverses an emitter's facing; a shape's to_uv is reported.
  func facing(_ document: ProjectDocument, _ name: String) -> SIMD3<Float>? {
    guard let asset = document.graph?.assets.first(where: { $0.name == name }), asset.geometry.count > 0 else { return nil }
    let t = asset.geometry.triangle(0)
    let a = SIMD3(t.a.x, t.a.y, t.a.z)
    return simd_normalize(simd_cross(SIMD3(t.b.x, t.b.y, t.b.z) - a, SIMD3(t.c.x, t.c.y, t.c.z) - a))
  }
  let panel = #"<emitter type="area"><rgb name="radiance" value="5"/></emitter><transform name="to_world"><rotate x="1" angle="90"/><translate y="2"/></transform>"#
  let flipped = try load("""
    <scene version="3.0.0">
      <shape type="rectangle" id="down">\(panel)</shape>
      <shape type="rectangle" id="up"><boolean name="flip_normals" value="true"/>\(panel)</shape>
      <shape type="rectangle" id="mapped"><transform name="to_uv"><scale x="2"/></transform></shape>
    </scene>
    """)
  let down = facing(flipped.document, "down"), up = facing(flipped.document, "up")
  let upNormal = flipped.document.graph?.assets.first { $0.name == "up" }?.geometry.vertices.first
  require((down?.y ?? 0) < -0.99 && (up?.y ?? 0) > 0.99 && (upNormal?[4] ?? 0) > 0.99,
    "flip_normals reverses a rectangle's winding and normals, and so the side it emits from (\(String(describing: down)), \(String(describing: up)))")
  require(flipped.report.contains("shape 'mapped': to_uv is not supported; ignored"), "a shape's to_uv is reported (\(flipped.report))")
  // A dielectric whose int_ior / ext_ior is below 1 (Glass of Water's air bubbles in ice) is the same interface seen from
  // its other side: the shape's facing is reversed (the material takes 1 / eta, Fix_mitsuba-materials.swift).
  let bubbleScene = try load("""
    <scene version="3.0.0">
      <shape type="rectangle" id="ice"><bsdf type="dielectric"><float name="int_ior" value="1.31"/><float name="ext_ior" value="1"/></bsdf></shape>
      <shape type="rectangle" id="bubble"><bsdf type="roughdielectric"><float name="int_ior" value="0.763"/><float name="ext_ior" value="1"/></bsdf></shape>
      <shape type="rectangle" id="pane"><bsdf type="thindielectric"><float name="int_ior" value="0.763"/><float name="ext_ior" value="1"/></bsdf></shape>
    </scene>
    """)
  let bubbles = bubbleScene.document
  require((facing(bubbles, "ice")?.z ?? 0) > 0.99 && (facing(bubbles, "bubble")?.z ?? 0) < -0.99 && (facing(bubbles, "pane")?.z ?? 0) > 0.99,
    "an IOR ratio below 1 reverses a dielectric's facing, not a thin dielectric's (\(String(describing: facing(bubbles, "bubble"))))")
  // A thin dielectric below 1 reflects totally beyond its critical angle in Mitsuba; the inverse ratio does not.
  require(bubbleScene.report.contains("rectangle2: thindielectric with an IOR ratio below 1 is rendered with the inverse ratio; its total internal reflection is lost"),
    "a thin dielectric below 1 is reported as an approximation (\(bubbleScene.report))")

  // The flip follows the BSDF the material mapping reaches (MitsubaImporter.leafBSDF): through twosided, mask,
  // bumpmap and normalmap an inverted dielectric's shape is reversed and reported; a wrapped one above 1 is not.
  let bumpImage = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 3,
    hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 24)!
  for i in 0..<48 { bumpImage.bitmapData![i] = i % 3 == 2 ? 255 : 128 }
  try bumpImage.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("bump.png"))
  func wrapped(_ kind: String, _ inner: String) -> String {
    switch kind {
    case "bumpmap": return #"<bsdf type="bumpmap"><texture type="bitmap" name="map"><string name="filename" value="bump.png"/></texture>\#(inner)</bsdf>"#
    case "normalmap":
      return #"<bsdf type="normalmap"><texture type="bitmap" name="normalmap"><string name="filename" value="bump.png"/><boolean name="raw" value="true"/></texture>\#(inner)</bsdf>"#
    default: return #"<bsdf type="\#(kind)">\#(inner)</bsdf>"#
    }
  }
  let inverted = #"<bsdf type="roughdielectric"><float name="int_ior" value="0.75"/><float name="ext_ior" value="1"/></bsdf>"#
  let upright = #"<bsdf type="dielectric"><float name="int_ior" value="1.5"/><float name="ext_ior" value="1"/></bsdf>"#
  for kind in ["twosided", "mask", "bumpmap", "normalmap"] {
    let result = try load("""
      <scene version="3.0.0">
        <shape type="rectangle" id="inverted">\(wrapped(kind, inverted))</shape>
        <shape type="rectangle" id="upright">\(wrapped(kind, upright))</shape>
      </scene>
      """)
    let reversed = result.report.contains { $0.hasPrefix("rectangle0: int_ior / ext_ior 0.75 is below 1;") && $0.hasSuffix("with the shape's facing reversed") }
    require((facing(result.document, "inverted")?.z ?? 0) < -0.99 && (facing(result.document, "upright")?.z ?? 0) > 0.99 && reversed
      && !result.report.contains { $0.hasPrefix("rectangle1: int_ior") },
      "\(kind) around a dielectric below 1 reverses the shape and says so; around one above 1 it does not (\(result.report))")
  }
  // flip_normals and the inverted IOR's reversal cancel: the winding is the unflipped file's.
  let cancelled = try load("""
    <scene version="3.0.0">
      <shape type="rectangle" id="both"><boolean name="flip_normals" value="true"/>\(inverted)</shape>
      <shape type="rectangle" id="neither"/>
    </scene>
    """).document
  require((facing(cancelled, "both")?.z ?? 0) > 0.99 && (facing(cancelled, "neither")?.z ?? 0) > 0.99,
    "flip_normals on a dielectric below 1 cancels the reversal (\(String(describing: facing(cancelled, "both"))))")
  // An emitter on such a shape keeps Mitsuba's side (the app's emission is one-sided by winding), so the shape is not
  // reversed and its glass is index-matched; an interior medium on a reversed shape would be outside it and is dropped.
  let sided = try load("""
    <scene version="3.0.0">
      <shape type="rectangle" id="lamp">\(inverted)<emitter type="area"><rgb name="radiance" value="2"/></emitter></shape>
      <shape type="rectangle" id="cavity">\(inverted)<medium type="homogeneous" name="interior"><rgb name="albedo" value="0"/><rgb name="sigma_t" value="1"/></medium></shape>
    </scene>
    """)
  func compiledMaterial(_ document: ProjectDocument, _ name: String) -> MaterialXProgram? {
    guard let slot = document.graph?.materials.first(where: { $0.name == name })?.slot else { return nil }
    return document.scenes[6]?.materialX?[slot]
  }
  let lampIOR = compiledMaterial(sided.document, "rectangle0_emitter")?.parameters.first { $0.name.hasSuffix("/specular_ior") }?.defaultValue?.x
  let cavity = compiledMaterial(sided.document, "rectangle1")
  require((facing(sided.document, "lamp")?.z ?? 0) > 0.99 && lampIOR == 1
    && sided.report.contains("rectangle0_emitter: int_ior / ext_ior 0.75 is below 1; rendered index-matched, so that the shape's emitter keeps its side"),
    "an emitter on a dielectric below 1 keeps its side; the glass is index-matched and reported (\(String(describing: lampIOR)), \(sided.report))")
  require((facing(sided.document, "cavity")?.z ?? 0) < -0.99 && cavity != nil && cavity?.medium == nil
    && sided.report.contains("rectangle1: interior medium ignored (the shape is reversed for its IOR ratio below 1, which puts Mitsuba's interior on its outside)"),
    "an interior medium on a reversed shape is dropped and reported (\(sided.report))")

  // An area emitter inside a dielectric (Little Lamp's filament in its bulb): Mitsuba's radiance is radiance in the
  // glass, the app's emission basic radiance, so the radiance is divided by eta^(2 n) of each dielectric its light
  // leaves n times on balance, with a report line (MitsubaImporter.emitterEnclosures). Closed and nested glass spheres,
  // an inverted dielectric (an air bubble, eta 1 / 1.5), a sphere with flip_normals (entered: brighter), a box open at
  // the top around a panel facing its floor (converted) and one facing the opening (disputed: reported, not converted);
  // unchanged: an emitter beside the glass, in a thindielectric, without glass, in the cavity of a thick shell of one
  // mesh, and inside a shell of two spheres (the inner one flipped), whose crossings cancel.
  try """
    v -1 -1 -1\nv 1 -1 -1\nv 1 1 -1\nv -1 1 -1\nv -1 -1 1\nv 1 -1 1\nv 1 1 1\nv -1 1 1
    f 1 2 6 5\nf 1 4 3 2\nf 5 6 7 8\nf 1 5 8 4\nf 2 3 7 6
    """.write(to: folder.appendingPathComponent("open-box.obj"), atomically: true, encoding: .utf8)
  // Outer faces wound outward, the inner cube's (0.8) inward: the glass is the space between them.
  let cubeFaces = [[1, 2, 6, 5], [1, 4, 3, 2], [5, 6, 7, 8], [1, 5, 8, 4], [2, 3, 7, 6], [4, 8, 7, 3]]
  let corners = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1), (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]
  let shellOBJ = ([1, 0.8].flatMap { scale in corners.map { "v \(Double($0.0) * scale) \(Double($0.1) * scale) \(Double($0.2) * scale)" } }
    + cubeFaces.map { "f " + $0.map(String.init).joined(separator: " ") }
    + cubeFaces.map { "f " + $0.reversed().map { String($0 + 8) }.joined(separator: " ") }).joined(separator: "\n")
  try shellOBJ.write(to: folder.appendingPathComponent("thick-shell.obj"), atomically: true, encoding: .utf8)
  func glassSphere(_ id: String, x: Float, radius: Float, int: Float, ext: Float, type: String = "roughdielectric", flipped: Bool = false) -> String {
    #"<shape type="sphere" id="\#(id)"><point name="center" x="\#(x)" y="0" z="0"/><float name="radius" value="\#(radius)"/>\#(flipped ? #"<boolean name="flip_normals" value="true"/>"# : "")<bsdf type="\#(type)"><float name="int_ior" value="\#(int)"/><float name="ext_ior" value="\#(ext)"/></bsdf></shape>"#
  }
  func filament(_ id: String, x: Float) -> String {
    #"<shape type="sphere" id="\#(id)"><point name="center" x="\#(x)" y="0" z="0"/><float name="radius" value="0.3"/><emitter type="area"><rgb name="radiance" value="9"/></emitter></shape>"#
  }
  func emitterPanel(_ id: String, x: Float, angle: Float) -> String {
    #"<shape type="rectangle" id="\#(id)"><transform name="to_world"><scale value="0.2"/><rotate x="1" angle="\#(angle)"/><translate x="\#(x)" y="-0.5"/></transform><emitter type="area"><rgb name="radiance" value="9"/></emitter></shape>"#
  }
  func glassOBJ(_ id: String, _ file: String, x: Float) -> String {
    #"<shape type="obj" id="\#(id)"><string name="filename" value="\#(file)"/><transform name="to_world"><translate x="\#(x)"/></transform><bsdf type="dielectric"><float name="int_ior" value="1.5"/><float name="ext_ior" value="1"/></bsdf></shape>"#
  }
  let enclosedXML = """
    <scene version="3.0.0">
      \(glassSphere("bulb", x: 0, radius: 1, int: 1.5, ext: 1))\(filament("filament", x: 0))
      \(filament("beside", x: 2))
      \(glassSphere("water", x: 10, radius: 2, int: 1.2, ext: 1))\(glassSphere("inner", x: 10, radius: 1, int: 1.5, ext: 1.2))\(filament("nested", x: 10))
      \(glassSphere("bubble", x: 20, radius: 1, int: 1, ext: 1.5))\(filament("bubbled", x: 20))
      \(glassSphere("pane", x: 30, radius: 1, int: 1.5, ext: 1, type: "thindielectric"))\(filament("thin", x: 30))
      \(glassOBJ("box", "open-box.obj", x: 40))\(emitterPanel("floorward", x: 40, angle: 90))
      \(glassOBJ("cup", "open-box.obj", x: 50))\(emitterPanel("skyward", x: 50, angle: -90))
      \(filament("bare", x: 60))
      \(glassOBJ("shell", "thick-shell.obj", x: 70))\(filament("cavity", x: 70))
      \(glassSphere("outerShell", x: 80, radius: 1, int: 1.5, ext: 1))\(glassSphere("innerShell", x: 80, radius: 0.8, int: 1.5, ext: 1, flipped: true))\(filament("split", x: 80))
      \(glassSphere("inverse", x: 90, radius: 1, int: 1.5, ext: 1, flipped: true))\(filament("entered", x: 90))
    </scene>
    """
  let enclosed = try load(enclosedXML)
  func surfaceInput(_ p: MaterialXProgram, _ name: String) -> SIMD3<Float>? {
    p.parameters.first { $0.name.hasSuffix("/" + name) }.flatMap { $0.defaultValue }.map { SIMD3($0.x, $0.y, $0.z) }
  }
  func radiance(_ name: String) -> SIMD3<Float>? {
    guard let shape = enclosed.document.graph?.nodes.first(where: { $0.name == name }), let id = shape.bindings.first,
      let program = compiledMaterial(enclosed.document, enclosed.document.graph?.materials.first { $0.id == id }?.name ?? "") else { return nil }
    return surfaceInput(program, "emission_color").map { $0 * (surfaceInput(program, "emission_luminance")?.x ?? 0) }
  }
  let insideGlass: [(String, Float)] = [("filament", 4), ("beside", 9), ("nested", 4), ("bubbled", 20.25), ("thin", 9), ("floorward", 4),
                                        ("skyward", 9), ("bare", 9), ("cavity", 9), ("split", 9), ("entered", 20.25)]
  let measuredRadiance = insideGlass.map { (name, _) in radiance(name)?.x ?? -1 }
  require(zip(insideGlass, measuredRadiance).allSatisfy { abs($1 - $0.1) < 1e-3 * $0.1 },
    "an area emitter's radiance is divided by eta^(2 n) of each dielectric its light leaves n times (\(measuredRadiance), expected \(insideGlass.map(\.1)))")
  let enclosureLines = enclosed.report.filter { $0.contains("dielectric '") }
  let converted = "radiance divided by 2.25, from Mitsuba's radiance in the glass to the app's"
  require(enclosureLines.count == 7
    && enclosureLines.contains("shape 'filament': area emitter inside dielectric 'bulb' (int_ior / ext_ior 1.5; 100% of test rays leave it once on balance); \(converted)")
    && enclosureLines.contains("shape 'nested': area emitter inside dielectric 'water' (int_ior / ext_ior 1.2; 100% of test rays leave it once on balance), inside dielectric 'inner' (int_ior / ext_ior 1.25; 100% of test rays leave it once on balance); \(converted)")
    && enclosureLines.contains("shape 'bubbled': area emitter inside dielectric 'bubble' (int_ior / ext_ior 0.666667; 100% of test rays leave it once on balance); radiance divided by 0.444444, from Mitsuba's radiance in the glass to the app's")
    && enclosureLines.contains { $0.hasPrefix("shape 'floorward': area emitter inside dielectric 'box' (int_ior / ext_ior 1.5; ") && $0.hasSuffix(converted) }
    && enclosureLines.contains { $0.hasPrefix("shape 'skyward': test rays from its area emitter disagree on dielectric 'cup' (int_ior / ext_ior 1.5): ")
      && $0.contains("leave it once on balance") && $0.contains("leave it as often as they enter it") && $0.hasSuffix("; radiance not converted (90% needed)") }
    && enclosureLines.contains("shape 'split': area emitter inside dielectric 'outerShell' (int_ior / ext_ior 1.5; 100% of test rays leave it once on balance), outside dielectric 'innerShell' (int_ior / ext_ior 1.5; 100% of test rays enter it once on balance); radiance unchanged, as these cancel")
    && enclosureLines.contains("shape 'entered': area emitter outside dielectric 'inverse' (int_ior / ext_ior 1.5; 100% of test rays enter it once on balance); radiance divided by 0.444444, from Mitsuba's radiance in the glass to the app's"),
    "each converted emitter, the disputed one and the cancelling shell have a report line; the thick shell's cavity has none (\(enclosureLines))")
  // The test budget: emitters past testLimit ray-triangle tests in all are left untested and counted.
  var budgetScene = try MitsubaImporter.Scene(url: try write("""
    <scene version="3.0.0">
      \(glassSphere("bulb", x: 0, radius: 1, int: 1.5, ext: 1))\(filament("first", x: 0))
      \(glassSphere("second bulb", x: 10, radius: 1, int: 1.5, ext: 1))\(filament("second", x: 10))
    </scene>
    """))
  let budgetShapes = budgetScene.root.children.filter { $0.tag == "shape" }
  let budgetMeshes = try MitsubaImporter.loadMeshes(budgetShapes, scene: &budgetScene, progress: nil)
  let noBudget = MitsubaImporter.emitterEnclosures(budgetShapes, budgetMeshes, testLimit: 0)
  let oneTest = MitsubaImporter.emitterEnclosures(budgetShapes, budgetMeshes, testLimit: 1)
  let unlimited = MitsubaImporter.emitterEnclosures(budgetShapes, budgetMeshes)
  require(noBudget.untested == 2 && noBudget.enclosures.isEmpty && oneTest.untested == 1 && oneTest.enclosures.keys.sorted() == [1]
    && unlimited.untested == 0 && unlimited.enclosures.keys.sorted() == [1, 3],
    "the test budget leaves the emitters after it untested (\(noBudget.untested), \(oneTest.untested), \(unlimited.untested))")
  print("PASS: Mitsuba scenes: area emitters inside dielectrics take the app's basic radiance")
  print("PASS: Mitsuba scenes: shapes, shared materials, camera and field of view, render size, depth, environment, report")

  // Open Scene File: a Mitsuba scene opens as an untitled document; an .xml that is not one fails and changes nothing.
  func idle() { waitUntil({ !controller.isBusy }, seconds: 60) }
  // Explicit undo groups, as in Fix_start-screen: the suite has no event loop grouping.
  let history = controller.history, groupsByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer { history.groupsByEvent = groupsByEvent }
  func open(_ url: URL) {
    history.beginUndoGrouping()
    controller.beginOpenSceneFile(url)
    idle()
    history.endUndoGrouping()
  }
  let sceneURL = try write(synthetic(), name: "open.xml")
  var reports = 0
  controller.importReportShown = { reports += 1 }
  defer { controller.importReportShown = nil }
  require(SceneFile.extensions.contains("xml"), "Open Scene File accepts .xml")
  // Unedited, so that no Save / Don't Save / Cancel prompt comes first.
  controller.associate(nil, edited: false, replaced: false)
  open(sceneURL)
  require(controller.projectURL == nil && controller.documentEdited && controller.project.graph?.assets.count == 3
    && controller.project.meshName == "open.xml" && controller.project.views["Mitsuba: camera"] != nil && reports == 1,
    "Open Scene File opens a Mitsuba scene as an untitled document (\(controller.errorMessage ?? "no error"), \(reports) reports)")
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  let before = try encoder.encode(controller.project)
  controller.dismissError()
  controller.associate(nil, edited: false, replaced: false)
  open(try write("<svg/>", name: "drawing.xml"))
  let after = try encoder.encode(controller.project)
  require(controller.errorMessage?.contains("drawing.xml is not a Mitsuba scene") == true && after == before && reports == 1, "an .xml that is not a Mitsuba scene fails with the importer's error and leaves the document unchanged (\(controller.errorMessage ?? "no error"), \(before.count) vs \(after.count) bytes)")
  controller.dismissError()
  print("PASS: Mitsuba scenes open through Open Scene File")

  // GPU: the floor under the emitting sphere is lit, and black without the sphere's emitter and the environment (the
  // importer adds no inspection sky to a Mitsuba scene).
  func floorRadiance(_ document: ProjectDocument, eye: SIMD3<Float>, samples: Int) throws -> SIMD3<Float> {
    try controller.restore(document)
    let o = document.options
    var v = makeUniforms(scene: 6, mode: 1, width: 32, height: 32)
    v.cameraPos = SIMD4(eye, 10); v.cameraTarget = SIMD4(0, 0, 0, 8)
    v.currentViewProj = makePerspective(fovyRadians: 10 * .pi / 180, aspect: 1, near: 0.05, far: 100)
      * makeLookAt(eye: eye, target: .zero, up: SIMD3(0, 1, 0))
    v.prevViewProj = v.currentViewProj
    v.environment = SIMD4(o.environmentIntensity, o.environmentRotation * .pi / 180, document.environmentData == nil ? 0 : 1,
                          Float(testRenderer.materials.nodeCount))
    v.sunParams.w = o.sunIntensity
    v.lens = SIMD4(0, o.focusDistance, 1, 0)
    let pixels = render(v, samples: samples)
    let centre = pixels.indices.filter { abs($0 % 32 - 16) < 8 && abs($0 / 32 - 16) < 8 }
    return centre.reduce(SIMD3<Float>()) { $0 + SIMD3(pixels[$1].x, pixels[$1].y, pixels[$1].z) } / Float(centre.count)
  }
  let lit = try floorRadiance(p, eye: SIMD3(0, 0.4, 1.5), samples: 64)
  let dark = try load(synthetic(lamp: lamp.replacingOccurrences(of: #"<emitter type="area"><rgb name="radiance" value="10"/></emitter>"#, with: ""), environment: ""))
  let unlit = try floorRadiance(dark.document, eye: SIMD3(0, 0.4, 1.5), samples: 16)
  print("Mitsuba synthetic scene: floor radiance under the sphere \(lit), without emitters \(unlit)")
  require(lit.min() > 0.01 && unlit.max() == 0 && dark.document.options.environmentIntensity == 0
    && dark.report.contains("No supported authored lighting: the scene is unlit."),
    "the emitting sphere lights the floor; without emitters the floor is black and the report says so (\(dark.report))")
  // Units: a 2 x 2 rectangle of radiance L facing a diffuse floor (rho 0.5) 2 below it gives the floor beneath its centre
  // radiance rho / pi x E, E = 4 L A / sqrt(1 + A^2) atan(A / sqrt(1 + A^2)), A = half-width / height (the form factor of a
  // parallel rectangle), 0.4789 for L 4.
  let units = try load("""
    <scene version="3.0.0">
      <shape type="rectangle" id="floor"><transform name="to_world"><scale value="20"/><rotate x="1" angle="-90"/></transform>
        <bsdf type="diffuse"><rgb name="reflectance" value="0.5"/></bsdf></shape>
      <shape type="rectangle" id="light"><transform name="to_world"><rotate x="1" angle="90"/><translate y="2"/></transform>
        <emitter type="area"><rgb name="radiance" value="4"/></emitter></shape>
    </scene>
    """).document
  let a: Float = 0.5, g = a / (1 + a * a).squareRoot() * atan(a / (1 + a * a).squareRoot())
  let expected = 0.5 / Float.pi * 4 * 4 * g
  let measured = try floorRadiance(units, eye: SIMD3(0, 0.6, 1), samples: 256)
  print("Mitsuba area emitter over a diffuse floor: radiance \(measured), expected \(expected)")
  require(abs(measured.x - expected) < 0.02 * expected && abs(measured.y - expected) < 0.02 * expected && abs(measured.z - expected) < 0.02 * expected,
    "an area emitter's radiance lights a diffuse floor in absolute units")
  print("PASS: Mitsuba scenes on the GPU: emitters light the floor, in absolute units")
}
try fixMitsubaSceneChecks()
