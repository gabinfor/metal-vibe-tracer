// Mitsuba scene import (MitsubaImporter), XML layer: <default> values and $variables, global <ref> ids
// (including a BSDF nested in another), <include>, transforms in document order, the Mitsuba 0.6 property
// names, and detection by root element; shapes (mesh files and analytic shapes as world-space triangles).
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

  let quad = try MitsubaImporter.mesh(try shapeNode(#"<shape type="rectangle"><transform name="to_world"><scale x="-1"/></transform></shape>"#), scene: &shapeScene)!
  require(quad.triangles.count == 2 && faceNormal(quad, 0).z > 0.99, "a mirrored rectangle still faces +z")
  require(quad.normals?.allSatisfy { simd_length($0 - SIMD3(0, 0, 1)) < 1e-6 } == true && quad.uvs?.count == 4, "rectangle normals and uvs")
  let plain = try MitsubaImporter.mesh(try shapeNode(#"<shape type="rectangle"/>"#), scene: &shapeScene)!
  require(plain.positions == [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)] && faceNormal(plain, 1).z > 0.99
    && plain.uvs![2] == SIMD2(1, 1), "rectangle spans -1...1 with uv 0...1")
  let disk = try MitsubaImporter.mesh(try shapeNode(#"<shape type="disk"><transform name="to_world"><scale y="-1"/></transform></shape>"#), scene: &shapeScene)!
  require(disk.triangles.count == 64 && disk.positions.count == 65 && (0..<64).allSatisfy { faceNormal(disk, $0).z > 0.99 }
    && disk.normals?.allSatisfy { $0 == SIMD3(0, 0, 1) } == true, "a mirrored disk: 64 triangles facing +z")
  let cube = try MitsubaImporter.mesh(try shapeNode(#"<shape type="cube"/>"#), scene: &shapeScene)!
  require(cube.triangles.count == 12 && cube.normals == nil && cube.uvs?.count == cube.positions.count
    && cube.positions.allSatisfy { $0.max() == 1 || $0.min() == -1 } && outward(cube, from: .zero), "cube: 12 outward triangles, flat normals")
  let mirroredCube = try MitsubaImporter.mesh(try shapeNode(#"<shape type="cube"><transform name="to_world"><scale x="-2"/></transform></shape>"#), scene: &shapeScene)!
  require(outward(mirroredCube, from: .zero), "a mirrored cube stays outward")
  let ball = try MitsubaImporter.mesh(try shapeNode(#"<shape type="sphere"><point name="center" x="1" y="0" z="0"/><float name="radius" value="2"/></shape>"#), scene: &shapeScene)!
  require(ball.positions.allSatisfy { abs(simd_length($0 - SIMD3(1, 0, 0)) - 2) < 1e-4 }, "sphere centre and radius")
  require(ball.normals.map { n in zip(n, ball.positions).allSatisfy { simd_length($0 - ($1 - SIMD3(1, 0, 0)) / 2) < 1e-4 } } == true
    && outward(ball, from: SIMD3(1, 0, 0)) && ball.uvs?.count == ball.positions.count, "sphere: smooth outward normals and uvs")
  let moved = try MitsubaImporter.mesh(try shapeNode("""
    <shape type="sphere"><float name="radius" value="2"/><transform name="to_world"><scale x="-1"/><translate y="3"/></transform></shape>
    """), scene: &shapeScene)!
  require(moved.positions.allSatisfy { abs(simd_length($0 - SIMD3(0, 3, 0)) - 2) < 1e-4 }
    && outward(moved, from: SIMD3(0, 3, 0)), "a sphere's to_world follows its radius; a mirrored one stays outward")

  _ = try write("tri.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0.5\nvt 1 0.25\nvt 0 0\nvn 0 0 1\nf 1/1/1 2/2/1 3/3/1\n")
  for file in ["tri.obj", "tri.ply", "tri-binary.ply", "tri.serialized"] {
    let m = try MitsubaImporter.mesh(try meshNode(file), scene: &shapeScene)!
    require(m.triangles.count == 1 && m.positions.count == 3 && m.uvs?.count == 3, "\(file) reads one triangle")
    require(abs(m.uvs![1].y - (1 - 0.25)) < 1e-6, "\(file): v is flipped")
    require(m.normals == [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)] && m.positions[1] == SIMD3(1, 0, 0), "\(file): positions and normals")
  }
  let second = try MitsubaImporter.mesh(try meshNode("tri.serialized", extra: #"<integer name="shape_index" value="1"/>"#), scene: &shapeScene)!
  require(second.positions == [SIMD3(0, 0, 5), SIMD3(1, 0, 5), SIMD3(0, 1, 5)] && second.uvs == nil && second.normals == [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
    "a serialized shape_index selects a double-precision sub-mesh without normals or uvs; smooth normals are computed")
  requireThrows("shape index") {
    _ = try MitsubaImporter.mesh(try meshNode("tri.serialized", extra: #"<integer name="shape_index" value="2"/>"#), scene: &shapeScene)
  }
  let placed = try MitsubaImporter.mesh(try meshNode("tri.ply", extra: #"<transform name="to_world"><scale z="2"/><translate x="1"/></transform>"#), scene: &shapeScene)!
  require(placed.positions[1] == SIMD3(2, 0, 0) && placed.normals?[0] == SIMD3(0, 0, 1), "to_world applies to positions and normals")
  let flatPly = try MitsubaImporter.mesh(try meshNode("tri-binary.ply", faceNormals: true), scene: &shapeScene)!
  require(flatPly.normals == nil && flatPly.uvs?.count == 3, "face_normals drops a file's normals")

  _ = try write("slanted.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nvn 0 1 1\nf 1//1 2//1 3//1\n")
  let slanted = try MitsubaImporter.mesh(try meshNode("slanted.obj", extra: #"<transform name="to_world"><scale z="2"/></transform>"#), scene: &shapeScene)!
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
  let flat = try MitsubaImporter.mesh(try meshNode("cube-no-normals.obj", faceNormals: true), scene: &shapeScene)!
  let smooth = try MitsubaImporter.mesh(try meshNode("cube-no-normals.obj"), scene: &shapeScene)!
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
  let polygon = try MitsubaImporter.mesh(try meshNode("polygons.obj"), scene: &shapeScene)!
  require(polygon.triangles == [SIMD3(0, 1, 2), SIMD3(0, 2, 3)] && polygon.positions.count == 4 && polygon.positions[0] == SIMD3(0, 0, 0),
    "negative indices count back from the vertices read so far; unused vertices are dropped; other statements are ignored")
  _ = try write("seams.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nvt 1 1\nvt 0.5 0.5\nf 1/1 2/2 3/3\nf 2/2 4/4 3/5\n")
  let seams = try MitsubaImporter.mesh(try meshNode("seams.obj"), scene: &shapeScene)!
  require(seams.positions.count == 5 && seams.triangles.count == 2 && seams.triangles[1].x == seams.triangles[0].y
    && seams.triangles[1].z != seams.triangles[0].z, "vertices weld per (position, uv, normal) triple")

  _ = try write("bad.obj", "v 0 0 0\nv 1 0 0\nf 1 2 3\n")
  requireThrows("invalid vertex index") { _ = try MitsubaImporter.mesh(try meshNode("bad.obj"), scene: &shapeScene) }
  _ = try write("big-endian.ply", "ply\nformat binary_big_endian 1.0\nelement vertex 0\nproperty float x\nend_header\n")
  requireThrows("big-endian") { _ = try MitsubaImporter.mesh(try meshNode("big-endian.ply"), scene: &shapeScene) }
  let truncated = try Data(contentsOf: fixtures.appendingPathComponent("tri-binary.ply")).dropLast(20)
  try truncated.write(to: folder.appendingPathComponent("truncated.ply"))
  requireThrows("truncated") { _ = try MitsubaImporter.mesh(try meshNode("truncated.ply"), scene: &shapeScene) }
  requireThrows("missing.obj") { _ = try MitsubaImporter.mesh(try meshNode("missing.obj"), scene: &shapeScene) }
  requireThrows("shape 'wall'") { _ = try MitsubaImporter.mesh(try meshNode("missing.obj", id: "wall"), scene: &shapeScene) }
  requireThrows("shape 'floor'") { _ = try MitsubaImporter.mesh(try meshNode("bad.obj", id: "floor"), scene: &shapeScene) }
  requireThrows("shape 'ply'") { _ = try MitsubaImporter.mesh(try meshNode("truncated.ply"), scene: &shapeScene) }
  let hair = try shapeNode(#"<shape type="hair"/>"#)
  let skipped = try MitsubaImporter.mesh(hair, scene: &shapeScene)
  require(skipped == nil && shapeScene.report.contains { $0.contains("shape hair") }, "unsupported shapes are reported")
  // Malformed and hostile files.
  func fails(_ fragment: String, _ file: String, extra: String = "") {
    requireThrows(fragment) { _ = try MitsubaImporter.mesh(try meshNode(file, extra: extra), scene: &shapeScene) }
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
  fails("truncated", "many-vertices.ply")
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
  let lf = try MitsubaImporter.mesh(try meshNode("lf.obj"), scene: &shapeScene)!, crlf = try MitsubaImporter.mesh(try meshNode("crlf.obj"), scene: &shapeScene)!
  require(lf.positions == crlf.positions && lf.uvs == crlf.uvs && lf.triangles == crlf.triangles && lf.normals == crlf.normals,
    "CRLF line endings, tabs and trailing comments read as the same mesh")
  _ = try write("zero-normal.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nvn 0 0 0\nf 1//1 2//1 3//1\n")
  let zeroNormal = try MitsubaImporter.mesh(try meshNode("zero-normal.obj"), scene: &shapeScene)!
  require(zeroNormal.normals?.allSatisfy { simd_length($0 - SIMD3(0, 0, 1)) < 1e-6 } == true, "a zero vn gives computed smooth normals")

  // Serialized files built here: a stored (uncompressed) DEFLATE block in a zlib stream.
  func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
  func zlib(_ body: [UInt8]) -> [UInt8] {
    [0x78, 0x01, 0x01] + bytes(UInt16(body.count)) + bytes(~UInt16(body.count)) + body + [0, 0, 0, 0]
  }
  func serialized(vertices: UInt64, faces: UInt64, payload: [UInt8], version: UInt16 = 4) -> [UInt8] {
    bytes(UInt16(0x041C)) + bytes(version) + zlib(bytes(UInt32(0x1000)) + Array("m\0".utf8) + bytes(vertices) + bytes(faces) + payload)
  }
  let positions = [Float](arrayLiteral: 0, 0, 0, 1, 0, 0, 0, 1, 0).flatMap { bytes($0.bitPattern) }
  let triangle = positions + bytes(UInt32(0)) + bytes(UInt32(1)) + bytes(UInt32(2))
  func serializedFails(_ fragment: String, _ name: String, _ content: [UInt8], extra: String = "") throws {
    try Data(content).write(to: folder.appendingPathComponent(name))
    fails(fragment, name, extra: extra)
  }
  let good = serialized(vertices: 3, faces: 1, payload: triangle)
  try Data(good).write(to: folder.appendingPathComponent("built.serialized"))
  let built = try MitsubaImporter.mesh(try meshNode("built.serialized"), scene: &shapeScene)!
  require(built.triangles == [SIMD3(0, 1, 2)], "the test's own serialized builder reads back")
  try serializedFails("outside the importer's limits", "huge-counts.serialized", serialized(vertices: 1 << 40, faces: 1 << 40, payload: triangle))
  try serializedFails("compressed size can hold", "bomb.serialized", serialized(vertices: 5_000_000, faces: 10_000_000, payload: triangle))
  try serializedFails("ends before", "short.serialized", serialized(vertices: 3, faces: 1, payload: Array(triangle.dropLast(4))))
  try serializedFails("more data", "long.serialized", serialized(vertices: 3, faces: 1, payload: triangle + [1, 2, 3, 4, 5, 6, 7, 8]))
  try serializedFails("version 5", "version5.serialized", serialized(vertices: 3, faces: 1, payload: triangle, version: 5))
  try serializedFails("compressed mesh data", "cut.serialized", Array(good.prefix(30)))
  try serializedFails("compressed mesh data", "not-zlib.serialized", Array(good.prefix(4)) + [0xFF, 0xFF, 1, 2, 3])
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
  require(unnamed.f0 == MitsubaTables.conductors["Cu"]!.f0, "no material and no eta: Cu")
  requireThrows("unknown conductor 'Kryptonite'") { _ = try MitsubaImporter.conductor(nodeWith("material", "Kryptonite")) }
  let eta = SIMD3<Float>(0.2, 0.9, 1.1), k = SIMD3<Float>(3.9, 2.4, 2.2)
  let explicit = try MitsubaImporter.conductor(etaKNode(eta: [eta.x, eta.y, eta.z], k: [k.x, k.y, k.z]))
  let expectedF0 = ((eta - 1) * (eta - 1) + k * k) / ((eta + 1) * (eta + 1) + k * k)
  require(simd_length(explicit.f0 - expectedF0) < 1e-4, "explicit eta, k through the Fresnel formula")
  // Mitsuba 3.9.1's conductor at these eta and k, sampled at mu = 1/7 as conductor_colors does.
  require(simd_length(explicit.tint - SIMD3(0.978395, 0.974457, 0.977413)) < 1e-4, "explicit eta, k: the 82-degree tint")
  requireThrows("not both") {
    _ = try MitsubaImporter.conductor(shapeNode(#"<bsdf type="conductor"><string name="material" value="Au"/><float name="eta" value="1"/></bsdf>"#))
  }
  // The fixture's ratios estimate the cosine-weighted mean transmittance with a 32 x 32 grid, about 0.8% above
  // its integral at low roughness; plasticRatio integrates it.
  var worst = (error: Float(0), row: "")
  for row in ratios.rows {
    let r = MitsubaImporter.plasticRatio(eta: row.eta, alpha: row.alpha, ggx: row.ggx, nonlinear: row.nonlinear, rho: row.rho)
    require(abs(r / row.ratio - 1) < 0.01, "plastic ratio within 1% of Mitsuba at \(row)")
    if abs(r / row.ratio - 1) > worst.error { worst = (abs(r / row.ratio - 1), "\(row)") }
  }
  print("Mitsuba plastic ratios: largest relative error \(worst.error) at \(worst.row)")
  print("PASS: Mitsuba values: named IORs and conductors, conductor Fresnel, plastic internal scattering")
}
try fixMitsubaChecks()
