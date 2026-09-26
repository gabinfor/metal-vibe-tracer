// Regression checks for interactions between the audit-remediation packages.
func fixIntegrationChecks() throws {
  // An imported UsdLux DistantLight's angular size (lights package) changes the
  // image, so undo/scene replacement (persistence package) must restart accumulation.
  var sunDisc = StudioOptions()
  sunDisc.sunAngle = 0.53
  require(!StudioOptions().sameRadiance(as: sunDisc), "imported sun angle is a radiance option")
  print("PASS: fix-integration radiance options include the imported sun angle")
}
try fixIntegrationChecks()
