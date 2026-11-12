// Mitsuba scene import (MitsubaImporter), XML layer: <default> values and $variables, global <ref> ids
// (including a BSDF nested in another), <include>, transforms in document order, the Mitsuba 0.6 property
// names, and detection by root element.
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
  require(scene.version == 3 && scene.root.children.first { $0.tag == "integrator" }?.float("max_depth") == 7, "defaults substitute")
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
  require(old.version == 0 && oldShape.child("to_world") != nil && oldBSDF.float("int_ior") == 1.33
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
  let unversioned = try MitsubaImporter.Scene(url: try write("noversion.xml", "<scene/>"))
  require(unversioned.version == 3, "a missing version counts as 3")

  var report = scene
  report.note("a"); report.note("b"); report.note("a")
  require(report.report == ["a", "b"], "report lines are kept once")
  require(scene.folder.standardizedFileURL == folder.standardizedFileURL, "folder is the scene's directory")

  let otherXMLURL = try write("other.xml", "<svg/>")
  require(MitsubaImporter.isMitsuba(defaultsURL) && !MitsubaImporter.isMitsuba(otherXMLURL)
    && !MitsubaImporter.isMitsuba(folder.appendingPathComponent("nothing.xml")), "detection by root element")
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

  let colours = try MitsubaImporter.Scene(url: try write("hex.xml", """
    <scene version="3.0.0">
      <bsdf type="diffuse" id="long"><rgb name="reflectance" value="#6d7185"/></bsdf>
      <bsdf type="diffuse" id="short"><rgb name="reflectance" value="#f80"/></bsdf>
      <bsdf type="diffuse" id="bad"><rgb name="reflectance" value="#12"/></bsdf>
      <bsdf type="diffuse" id="spaced"><rgb name="reflectance" value=" 0.5 , 0.25  0.125 "/></bsdf>
    </scene>
    """))
  func colour(_ id: String) -> SIMD3<Float>? { colours.root.children.first { $0.id == id }?.rgb("reflectance") }
  func srgbToLinear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
  let long = colour("long") ?? .zero, short = colour("short") ?? .zero
  require(simd_length(long - SIMD3(srgbToLinear(0x6d / 255), srgbToLinear(0x71 / 255), srgbToLinear(0x85 / 255))) < 1e-6, "#rrggbb is sRGB decoded")
  require(simd_length(short - SIMD3(1, srgbToLinear(8 / 15), 0)) < 1e-6, "#rgb is sRGB decoded")
  require(colour("bad") == nil && colour("spaced") == SIMD3(0.5, 0.25, 0.125), "a bad hex colour is nil; commas and spaces mix")
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
  print("PASS: Mitsuba XML layer: defaults, variables, references, includes, transforms, hex colours, 0.6 names")
}
try fixMitsubaChecks()
