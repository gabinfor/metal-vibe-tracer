// Mitsuba sensors (MitsubaImporter.camera): the camera looks from the sensor's origin toward its target with the
// image not mirrored, the report is quiet about area-emitter-only lighting, and film and sensor settings that
// change the image but are not represented are reported.
@MainActor func fixMitsubaCameraChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("mitsuba-camera", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  var written = 0
  func load(_ xml: String) throws -> USDImportResult {
    written += 1
    let url = folder.appendingPathComponent("scene\(written).xml")
    try xml.write(to: url, atomically: true, encoding: .utf8)
    return try MitsubaImporter.load(url, into: ProjectDocument())
  }
  let lamp = #"<shape type="sphere"><emitter type="area"><rgb name="radiance" value="10"/></emitter></shape>"#
  func scene(sensor: String, lamp light: String = lamp) -> String {
    #"<scene version="3.0.0">\#(sensor)\#(light)</scene>"#
  }
  func sensor(origin: String = "0, 1, 5", sensorProperties: String = "", filmProperties: String = "") -> String {
    """
    <sensor type="perspective"><float name="fov" value="45"/>\(sensorProperties)
      <transform name="to_world"><lookat origin="\(origin)" target="0, 0.5, 0" up="0, 1, 0"/></transform>
      <film type="hdrfilm"><integer name="width" value="640"/><integer name="height" value="480"/>\(filmProperties)</film>
    </sensor>
    """
  }

  // Direction, up and handedness of the active camera, for a lookat with a yaw and a pitch.
  let origin = SIMD3<Float>(3, 1, 2), target = SIMD3<Float>(0, 0.5, 0)
  let camera = try load(scene(sensor: sensor(origin: "3, 1, 2"))).document.camera
  let eye = camera.target + camera.distance * SIMD3(cos(camera.pitch) * sin(camera.yaw), sin(camera.pitch), -cos(camera.pitch) * cos(camera.yaw))
  let forward = simd_normalize(camera.target - eye)
  let up = SIMD3(-sin(camera.pitch) * sin(camera.yaw), cos(camera.pitch), sin(camera.pitch) * cos(camera.yaw))
  let expectedForward = simd_normalize(target - origin)
  let expectedRight = simd_normalize(simd_cross(expectedForward, SIMD3<Float>(0, 1, 0)))
  let expectedUp = simd_cross(expectedRight, expectedForward)
  require(simd_length(eye - origin) < 1e-4, "the camera sits at the lookat's origin (\(eye))")
  require(simd_length(forward - expectedForward) < 1e-4, "the camera looks from the origin toward the target (\(forward) for \(expectedForward))")
  require(up.y > 0 && simd_length(up - expectedUp) < 1e-4, "the camera's up is Mitsuba's (\(up) for \(expectedUp))")
  require(simd_length(simd_cross(forward, up) - expectedRight) < 1e-4, "the image is not mirrored (right \(simd_cross(forward, up)) for \(expectedRight))")

  // Area emitters are the scene's authored lights: no report line about environment or sun; no emitters at all is unlit.
  let lit = try load(scene(sensor: sensor()))
  require(!lit.report.contains { $0.contains("no environment or sun") } && !lit.report.contains { $0.contains("unlit") },
    "an area-emitter scene reports nothing about its lighting (\(lit.report))")
  let unlit = try load(scene(sensor: sensor(), lamp: #"<shape type="sphere"/>"#))
  require(unlit.report.contains("No supported authored lighting: the scene is unlit."), "a scene without lights is reported unlit (\(unlit.report))")

  // Settings that change the image and are not represented.
  let crop = "film crop is not supported; the full frame is rendered"
  let principal = "principal point offset is not supported; ignored"
  func report(_ sensorProperties: String = "", film: String = "") -> [String] {
    (try? load(scene(sensor: sensor(sensorProperties: sensorProperties, filmProperties: film))).report) ?? ["load failed"]
  }
  require(report().isEmpty, "a plain sensor reports nothing")
  for property in [#"<integer name="crop_offset_x" value="10"/>"#, #"<integer name="crop_offset_y" value="10"/>"#,
                   #"<integer name="crop_width" value="320"/>"#, #"<integer name="crop_height" value="240"/>"#] {
    require(report(film: property) == [crop], "film crop is reported for \(property)")
  }
  require(report(film: #"<integer name="crop_offset_x" value="0"/><integer name="crop_width" value="640"/><integer name="crop_height" value="480"/>"#).isEmpty,
    "a crop of the full frame is not reported")
  for property in [#"<float name="principal_point_offset_x" value="0.1"/>"#, #"<float name="principal_point_offset_y" value="-0.1"/>"#] {
    require(report(property) == [principal], "the principal point offset is reported for \(property)")
  }
  require(report(#"<float name="principal_point_offset_x" value="0"/>"#).isEmpty, "a zero principal point offset is not reported")
  require(report(#"<float name="near_clip" value="0.5"/>"#) == ["near_clip 0.5 is not supported; ignored"], "a near_clip other than 0.01 is reported")
  require(report(#"<float name="near_clip" value="0.01"/><float name="far_clip" value="500"/>"#).isEmpty,
    "the default near_clip and any far_clip are not reported")
  print("PASS: Mitsuba camera: direction, up and handedness, quiet area-emitter report, unsupported film and sensor settings")
}
try fixMitsubaCameraChecks()
