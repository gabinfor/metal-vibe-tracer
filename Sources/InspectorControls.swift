import Cocoa

// The inspector's control vocabulary: the control classes and the row builders every inspector page uses.
//
// Each builder adds one row to `stack` (StudioController) and returns its control. Rows put the label on the left and
// the control right-aligned in a column shared by every row, with an 18-pt slot at the end for reset buttons. Edits
// are ignored while `acceptsEdits` is false.
//
//   section("Quality")                                          section heading (14 pt semibold) with space above
//   collapsible("Advanced", key: "render.advanced") { … }       disclosure + heading; the body is built only while open
//   popupRow("Tone map", ["Filmic fit", "Linear"], i) { i in … } label + popup
//   toggle("MetalFX preview", isOn) { on in … }                 label + small NSSwitch
//   number("Exposure, EV", v, -16...16, 0, step: 0.1) { v in … } label, field, reset; slider beneath
//   option("Sun intensity", \.sunIntensity, 0...10000, 850)    number row bound to a StudioOptions key path
//   vector("Position", p, -100...100, .zero) { p in … }         three compact fields X/Y/Z (or R/G/B), one reset
//   colorRow("Light colour", linear) { rgb in … }               label + colour well; linear RGB in and out
//   button("Render and Export…", style: .primary) { … }         full-width button: .normal, .primary, .destructive
//   buttonRow([ActionButton("Update") { … }, ActionButton("Delete", style: .destructive) { … }])
//   hint("Drag to orbit, Shift-drag to pan.")                   one short secondary line
//
// Undo: number, vector, toggle and colour rows record their own undo step (named after the row's title) before
// calling the setter, then call `changed(reset:)`; `reset: false` keeps the accumulated samples (display-only
// settings). Popup and button actions record their own. A slider drag is one undo step: the first change of the drag
// records it, later changes do not. `live: false` number rows (expensive setters: graph transforms, MaterialX
// parameters) commit once on release while the field tracks the knob. Number rows snap slider values to `step`
// (a 1–2–5 value near range/200 unless given; Option disables snapping) and switch to a logarithmic slider for ranges
// spanning more than two decades (`scale:` overrides). ↑/↓ in a field step by one step, Shift by ten, Option by a tenth.
//
// Collapsible sections remember their state in `preferences` (UserDefaults) under "InspectorSection.<key>";
// `forceSectionsOpen` (tests) builds every body.
//
// Older helpers for pages not yet converted: heading (section heading without the space above), text (= hint),
// caption (a small label above a control), popup (a full-width popup without a row label).

// The width of the trailing slot every row ends with (a reset button or empty space).
let inspectorGutter: CGFloat = 18

enum InspectorButtonStyle { case normal, primary, destructive }

final class ActionButton: NSButton {
  var actionBlock: (() -> Void)?
  convenience init(_ title: String, style: InspectorButtonStyle = .normal, _ action: @escaping () -> Void) {
    self.init(frame: .zero)
    self.title = title
    bezelStyle = .rounded
    target = self
    self.action = #selector(invoke)
    actionBlock = action
    switch style {
    case .normal: break
    case .primary: bezelColor = .controlAccentColor
    case .destructive: contentTintColor = .systemRed
    }
  }
  @objc func invoke() { actionBlock?() }
}
final class ActionPopup: NSPopUpButton {
  var actionBlock: ((Int) -> Void)?
  convenience init(
    _ titles: [String], selected: Int, label: String? = nil, _ action: @escaping (Int) -> Void
  ) {
    self.init(frame: .zero, pullsDown: false)
    // Menu items rather than addItems(withTitles:), which drops an earlier item of the same title: the action
    // indexes `titles` (two nodes or materials can share a name).
    for title in titles { menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: "")) }
    if let label { setAccessibilityLabel(label) }
    selectItem(at: selected)
    target = self
    self.action = #selector(invoke)
    actionBlock = action
  }
  @objc func invoke() { actionBlock?(indexOfSelectedItem) }
}
final class ActionSwitch: NSSwitch {
  var actionBlock: ((Bool) -> Void)?
  convenience init(_ isOn: Bool, label: String, _ action: @escaping (Bool) -> Void) {
    self.init(frame: .zero)
    controlSize = .small
    state = isOn ? .on : .off
    setAccessibilityLabel(label)
    target = self
    self.action = #selector(invoke)
    actionBlock = action
  }
  var isOn: Bool { state == .on }
  @objc func invoke() { actionBlock?(isOn) }
}
final class ActionSegmentedControl: NSSegmentedControl {
  var actionBlock: ((Int) -> Void)?
  convenience init(_ labels: [String], selected: Int, label: String, _ action: @escaping (Int) -> Void) {
    self.init(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
    selectedSegment = selected
    setAccessibilityLabel(label)
    target = self
    self.action = #selector(invoke)
    actionBlock = action
  }
  @objc func invoke() { actionBlock?(selectedSegment) }
}

enum NumberScale { case linear, logarithmic }

// The slider of a NumberControl: AppKit tracks the mouse inside mouseDown until the button is released, which
// brackets every drag (and click on the track) for its owner.
final class InspectorSlider: NSSlider {
  weak var owner: NumberControl?
  override func mouseDown(with event: NSEvent) {
    owner?.beginDrag()
    super.mouseDown(with: event)
    owner?.endDrag()
  }
}

// A number row: label, field and reset button with a slider beneath, or (compact) the field alone for vector rows.
// `update` receives every committed value; `continuesDrag` is true while it delivers the second or later change of
// one slider drag, so the owner can record one undo step per drag.
final class NumberControl: NSStackView, NSTextFieldDelegate {
  let field = NSTextField(), slider = InspectorSlider()
  var update: ((Float) -> Void)!
  var minimum: Float = 0, maximum: Float = 1
  // Typed values may exceed the slider range up to these limits.
  var entryMinimum: Float = 0, entryMaximum: Float = 1
  // Whole-number controls round typed and slider values and show no decimals.
  var integral = false
  // The slider's snapping step (for a logarithmic slider, the finest one) and the field's arrow-key increment.
  let step: Float
  let scale: NumberScale
  // Live controls publish while the slider is dragged; others publish on release.
  let live: Bool
  let defaultValue: Float
  // Shown (and accepted when typed) for 0, for example "Unlimited".
  let zeroText: String?
  // The last published value.
  private(set) var value: Float
  // Text of the last published value; ending editing with it unchanged commits nothing.
  private(set) var displayed = ""
  var onReject: ((String) -> Void)?
  // Called when a slider drag ends (StudioController runs a rebuild it deferred during the drag).
  var onDragEnd: (() -> Void)?
  private(set) var isDragging = false
  private(set) var continuesDrag = false
  private var dragPublished = false, dragPending: Float?
  // The control whose slider is being dragged, if any.
  private(set) static weak var dragging: NumberControl?
  private(set) var resetButton: NSButton?
  // The offset of a logarithmic slider's curve: positions map to value - minimum + knee on a log scale.
  private let knee: Float

  init(
    _ title: String, value: Float, range: ClosedRange<Float>, defaultValue: Float,
    entry: ClosedRange<Float>? = nil, integral: Bool = false, step: Float? = nil, scale: NumberScale? = nil,
    live: Bool = false, compact: Bool = false, zeroText: String? = nil, help: String? = nil,
    _ action: @escaping (Float) -> Void
  ) {
    self.integral = integral
    self.defaultValue = defaultValue
    self.zeroText = zeroText
    self.live = live
    self.value = value
    let resolvedScale = scale ?? Self.automaticScale(range)
    self.scale = resolvedScale
    let lower = range.lowerBound, upper = range.upperBound
    knee = lower > 0 ? lower : integral ? 1 : max((upper - lower) * 1e-4, Float.leastNormalMagnitude)
    self.step = step ?? (resolvedScale == .logarithmic
      ? (integral ? 1 : Self.niceStep(near: knee / 10)) : Self.automaticStep(range, integral: integral))
    super.init(frame: .zero)
    minimum = lower
    maximum = upper
    entryMinimum = min(minimum, entry?.lowerBound ?? minimum)
    entryMaximum = max(maximum, entry?.upperBound ?? maximum)
    update = action
    orientation = .vertical
    alignment = .leading
    spacing = 2
    field.alignment = .right
    field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    field.target = self
    field.action = #selector(typed)
    field.delegate = self
    (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
    field.setAccessibilityLabel(title)
    field.toolTip = help
    if let help { field.setAccessibilityHelp(help) }
    slider.owner = self
    slider.controlSize = .small
    slider.isContinuous = true
    slider.target = self
    slider.action = #selector(slid)
    slider.setAccessibilityLabel(title)
    slider.toolTip = help
    if resolvedScale == .linear {
      slider.minValue = Double(minimum)
      slider.maxValue = Double(maximum)
    } else {
      slider.minValue = 0
      slider.maxValue = 1
    }
    if compact {
      field.controlSize = .small
      field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      addArrangedSubview(field)
      field.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    } else {
      let label = inspectorLabel(title, help: help)
      let reset = NSButton(
        image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset \(title)")!,
        target: self, action: #selector(resetToDefault))
      reset.isBordered = false
      reset.imageScaling = .scaleProportionallyDown
      reset.contentTintColor = .secondaryLabelColor
      reset.toolTip = "Reset to \(format(defaultValue))"
      reset.setAccessibilityLabel("Reset \(title)")
      reset.widthAnchor.constraint(equalToConstant: inspectorGutter).isActive = true
      resetButton = reset
      field.widthAnchor.constraint(equalToConstant: 72).isActive = true
      let row = inspectorRow(label, field, trailing: reset)
      addArrangedSubview(row)
      addArrangedSubview(slider)
      row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
      // The slider ends under the field, clear of the reset column.
      slider.widthAnchor.constraint(equalTo: widthAnchor, constant: -(inspectorGutter + 6)).isActive = true
    }
    show(value)
  }
  required init?(coder: NSCoder) { fatalError() }

  // Publishes `value` (clamped to the entry range, rounded for integral controls) as one discrete change.
  func set(_ value: Float) {
    guard value.isFinite else {
      NSSound.beep()
      return
    }
    let v = min(entryMaximum, max(entryMinimum, integral ? value.rounded() : value))
    show(v)
    publish(v)
  }
  @objc func resetToDefault() { set(defaultValue) }
  // Shows `value` (clamped and rounded like set) without publishing it.
  func display(_ value: Float) {
    guard value.isFinite else { return }
    self.value = min(entryMaximum, max(entryMinimum, integral ? value.rounded() : value))
    show(self.value)
  }
  private func publish(_ v: Float) {
    value = v
    update(v)
  }
  // Shows `v` in the field, on the slider and in the reset button's visibility, without publishing it.
  private func show(_ v: Float, moveKnob: Bool = true) {
    field.stringValue = format(v)
    displayed = field.stringValue
    if moveKnob { slider.doubleValue = position(of: v) }
    resetButton?.isHidden = v == defaultValue
  }

  // MARK: Formatting and parsing

  func format(_ v: Float) -> String {
    if let zeroText, v == 0 { return zeroText }
    if integral { return Self.trimmed(String(format: "%.0f", Double(v))) }
    return Self.format(v, decimals: Self.decimals(for: stepAt(v)))
  }
  // `v` at `decimals` places with trailing zeros trimmed, or to six significant digits when it has more precision
  // (a typed or computed value off the step).
  nonisolated static func format(_ v: Float, decimals: Int) -> String {
    let fixed = String(format: "%.\(decimals)f", Double(v))
    if let back = Float(fixed), abs(back - v) <= 4 * v.ulp { return trimmed(fixed) }
    return trimmed(String(format: "%.6g", Double(v)))
  }
  nonisolated static func trimmed(_ text: String) -> String {
    var s = text
    if s.contains("."), !s.contains("e") {
      while s.hasSuffix("0") { s.removeLast() }
      if s.hasSuffix(".") { s.removeLast() }
    }
    return s == "-0" ? "0" : s
  }
  // The decimal places a step needs: 1 → 0, 0.5 → 1, 0.05 → 2, 0.005 → 3.
  nonisolated static func decimals(for step: Float) -> Int {
    guard step > 0, step < 1 else { return 0 }
    return max(0, Int((-log10(Double(step)) - 1e-4).rounded(.up)))
  }
  // Accepts POSIX input, then the current locale (for example "0,25"), ignoring whitespace.
  static func parse(_ text: String, locale: Locale = .current) -> Float? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value = Float(trimmed) { return value }
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    if let value = formatter.number(from: trimmed)?.floatValue { return value }
    if !trimmed.contains("."), trimmed.filter({ $0 == "," }).count == 1 {
      return Float(trimmed.replacingOccurrences(of: ",", with: "."))
    }
    return nil
  }

  // MARK: Steps and slider mapping

  // The 1–2–5 value (…, 0.1, 0.2, 0.5, 1, 2, 5, 10, …) closest to `x` on a log scale.
  nonisolated static func niceStep(near x: Float) -> Float {
    guard x.isFinite, x > 0 else { return 1 }
    let magnitude = pow(10, floor(log10(Double(x))))
    let best = [1.0, 2, 5, 10].map { $0 * magnitude }.min { abs(log($0 / Double(x))) < abs(log($1 / Double(x))) }!
    return Float(String(format: "%g", best))!
  }
  nonisolated static func automaticStep(_ range: ClosedRange<Float>, integral: Bool) -> Float {
    let step = niceStep(near: (range.upperBound - range.lowerBound) / 200)
    return integral ? max(1, step.rounded()) : step
  }
  // Logarithmic for non-negative ranges spanning more than two decades (0…N counts as such from N = 1000).
  nonisolated static func automaticScale(_ range: ClosedRange<Float>) -> NumberScale {
    let a = range.lowerBound, b = range.upperBound
    guard a >= 0, b > 0 else { return .linear }
    return (a > 0 ? b / a > 100 : b >= 1000) ? .logarithmic : .linear
  }
  // The snapping step at `v`: `step` on a linear slider; about 2% of the value (never below `step`) on a
  // logarithmic one.
  func stepAt(_ v: Float) -> Float {
    guard scale == .logarithmic else { return step }
    let relative = Self.niceStep(near: max(abs(v), knee) / 50)
    return max(step, integral ? relative.rounded() : relative)
  }
  // `v` rounded to a multiple of `s`, as the float nearest that decimal value.
  nonisolated static func snap(_ v: Float, to s: Float) -> Float {
    guard s > 0 else { return v }
    let multiple = (Double(v) / Double(s)).rounded() * Double(s)
    return Float(String(format: "%.\(decimals(for: s))f", multiple)) ?? v
  }
  // The slider position of `v`: the value itself on a linear slider, 0…1 on a logarithmic one. The range ends map
  // to the slider ends exactly.
  func position(of v: Float) -> Double {
    guard scale == .logarithmic else { return Double(min(maximum, max(minimum, v))) }
    if v <= minimum { return 0 }
    if v >= maximum { return 1 }
    return log(Double((v - minimum) / knee) + 1) / log(Double((maximum - minimum) / knee) + 1)
  }
  // The value at slider position `p`, snapped to the step unless `snapping` is false, within the slider range.
  func value(atPosition p: Double, snapping: Bool = true) -> Float {
    var v: Float
    if scale == .linear {
      v = Float(p)
    } else if p <= 0 {
      v = minimum
    } else if p >= 1 {
      v = maximum
    } else {
      v = minimum + knee * Float(expm1(p * log(Double((maximum - minimum) / knee) + 1)))
    }
    if snapping { v = Self.snap(v, to: stepAt(v)) }
    if integral { v = v.rounded() }
    return min(maximum, max(minimum, v))
  }

  // MARK: Editing

  @objc func typed() {
    // Ending editing (focus loss, inspector rebuild) re-sends the unchanged text.
    guard field.stringValue != displayed else { return }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if let zeroText, text.caseInsensitiveCompare(zeroText) == .orderedSame {
      set(0)
      return
    }
    guard let value = Self.parse(text), value.isFinite else {
      let rejected = field.stringValue
      field.stringValue = displayed
      NSSound.beep()
      onReject?("“\(rejected)” is not a number.")
      return
    }
    set(value)
  }
  // ↑/↓ in the field: one step up or down, ten with Shift, a tenth with Option (whole steps for integral controls).
  func nudge(_ direction: Float, modifiers: NSEvent.ModifierFlags = []) {
    if field.stringValue != displayed { typed() }
    let factor: Float = modifiers.contains(.shift) ? 10 : modifiers.contains(.option) ? 0.1 : 1
    var delta = stepAt(value) * factor
    if integral { delta = max(1, delta.rounded()) }
    set(Self.snap(value + direction * delta, to: delta))
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126,
      !event.modifierFlags.contains(.command)
    else { return false }
    nudge(event.keyCode == 126 ? 1 : -1, modifiers: event.modifierFlags)
    textView.string = field.stringValue
    textView.selectAll(nil)
    return true
  }
  // The slider's action. Outside a drag (keyboard) it is one discrete change; during a drag a live control publishes
  // each new snapped value and a non-live one only shows it.
  @objc func slid() {
    let v = value(atPosition: slider.doubleValue, snapping: !NSEvent.modifierFlags.contains(.option))
    guard isDragging else {
      set(v)
      return
    }
    guard live else {
      dragPending = v
      show(v, moveKnob: false)
      return
    }
    guard v != value else { return }
    continuesDrag = dragPublished
    dragPublished = true
    show(v, moveKnob: false)
    publish(v)
    continuesDrag = false
  }
  func beginDrag() {
    isDragging = true
    dragPublished = false
    dragPending = nil
    Self.dragging = self
  }
  func endDrag() {
    isDragging = false
    if Self.dragging === self { Self.dragging = nil }
    if let pending = dragPending, pending != value {
      set(pending)
    } else {
      show(value)
    }
    dragPending = nil
    dragPublished = false
    onDragEnd?()
  }
}

// Three compact number fields on one line (X Y Z or R G B) with one reset button for the triple.
final class VectorControl: NSStackView {
  let components: [NumberControl]
  private(set) var value: SIMD3<Float>
  let defaultValue: SIMD3<Float>
  var update: ((SIMD3<Float>) -> Void)!
  private(set) var resetButton: NSButton!
  init(
    _ title: String, value: SIMD3<Float>, range: ClosedRange<Float>, defaultValue: SIMD3<Float>,
    labels: [String] = ["X", "Y", "Z"], entry: ClosedRange<Float>? = nil, integral: Bool = false, step: Float? = nil,
    help: String? = nil, _ action: @escaping (SIMD3<Float>) -> Void
  ) {
    self.value = value
    self.defaultValue = defaultValue
    var fields: [NumberControl] = []
    for i in 0..<3 {
      fields.append(
        NumberControl(
          "\(title) \(labels[i])", value: value[i], range: range, defaultValue: defaultValue[i], entry: entry,
          integral: integral, step: step, scale: .linear, compact: true, help: help) { _ in })
    }
    components = fields
    super.init(frame: .zero)
    update = action
    orientation = .horizontal
    spacing = 6
    detachesHiddenViews = false
    let reset = NSButton(
      image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset \(title)")!,
      target: self, action: #selector(resetToDefault))
    reset.isBordered = false
    reset.imageScaling = .scaleProportionallyDown
    reset.contentTintColor = .secondaryLabelColor
    reset.setAccessibilityLabel("Reset \(title)")
    reset.widthAnchor.constraint(equalToConstant: inspectorGutter).isActive = true
    resetButton = reset
    addArrangedSubview(inspectorLabel(title, help: help))
    for (i, field) in fields.enumerated() {
      let letter = NSTextField(labelWithString: labels[i])
      letter.font = .systemFont(ofSize: 10)
      letter.textColor = .secondaryLabelColor
      let pair = NSStackView(views: [letter, field])
      pair.spacing = 2
      pair.setHuggingPriority(.defaultHigh, for: .horizontal)
      field.widthAnchor.constraint(equalToConstant: 46).isActive = true
      field.update = { [weak self] v in
        guard let self else { return }
        var next = self.value
        next[i] = v
        self.publish(next)
      }
      addArrangedSubview(pair)
    }
    addArrangedSubview(reset)
    reset.isHidden = value == defaultValue
  }
  required init?(coder: NSCoder) { fatalError() }
  // Publishes the whole triple as one change.
  func set(_ v: SIMD3<Float>) {
    for i in 0..<3 { components[i].display(v[i]) }
    publish(SIMD3(components[0].value, components[1].value, components[2].value))
  }
  @objc func resetToDefault() {
    guard value != defaultValue else { return }
    set(defaultValue)
  }
  private func publish(_ v: SIMD3<Float>) {
    value = v
    resetButton.isHidden = v == defaultValue
    update(v)
  }
}
final class ActionColor: NSColorWell {
  var update: ((NSColor) -> Void)?
  convenience init(_ color: NSColor, label: String? = nil, _ action: @escaping (NSColor) -> Void) {
    self.init(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
    self.color = color
    if let label { setAccessibilityLabel(label) }
    update = action
    target = self
    self.action = #selector(changed)
  }
  @objc func changed() { update?(color) }
}
final class TopAlignedStackView: NSStackView {
  override var isFlipped: Bool { true }
}

// A row's label: 12 pt, truncated with the full text in the tooltip when it does not fit.
@MainActor func inspectorLabel(_ title: String, help: String? = nil) -> NSTextField {
  let label = NSTextField(labelWithString: title)
  label.font = .systemFont(ofSize: 12)
  label.lineBreakMode = .byTruncatingTail
  label.toolTip = help ?? title
  label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  label.setContentHuggingPriority(.defaultLow, for: .horizontal)
  return label
}
// Label on the left, `control` right-aligned, then `trailing` (or empty space) in the reset column.
@MainActor func inspectorRow(_ label: NSView, _ control: NSView, trailing: NSView? = nil) -> NSStackView {
  let slot = trailing ?? NSView()
  if trailing == nil { slot.widthAnchor.constraint(equalToConstant: inspectorGutter).isActive = true }
  control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
  control.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
  let row = NSStackView(views: [label, control, slot])
  row.orientation = .horizontal
  row.alignment = .centerY
  row.spacing = 6
  row.detachesHiddenViews = false
  return row
}

extension StudioController {
  func add(_ v: NSView) {
    for control in Self.numberControls(in: v) {
      if control.onReject == nil { control.onReject = { [weak self] message in self?.show(message) } }
      if control.onDragEnd == nil { control.onDragEnd = { [weak self] in self?.runDeferredRebuild() } }
    }
    stack.addArrangedSubview(v)
    v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
  }
  static func numberControls(in view: NSView) -> [NumberControl] {
    ((view as? NumberControl).map { [$0] } ?? []) + view.subviews.flatMap { numberControls(in: $0) }
  }

  // MARK: Text

  func text(_ value: String) {
    let label = NSTextField(wrappingLabelWithString: value)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    add(label)
  }
  // One short secondary line; longer explanations belong in a control's `help` (tooltip and accessibility help).
  func hint(_ value: String) { text(value) }
  // A small label naming the control below it.
  func caption(_ value: String) {
    let label = NSTextField(labelWithString: value)
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .secondaryLabelColor
    add(label)
  }
  func heading(_ value: String) {
    let l = NSTextField(labelWithString: value)
    l.font = .systemFont(ofSize: 14, weight: .semibold)
    add(l)
  }
  // A section heading with extra space above it.
  func section(_ title: String) {
    if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(18, after: last) }
    heading(title)
  }
  // A section with a disclosure triangle: `body` adds its rows only while it is open. The state is kept in
  // `preferences` under "InspectorSection.<key>"; `forceSectionsOpen` opens every section.
  func collapsible(_ title: String, key: String, initiallyOpen: Bool = false, _ body: () -> Void) {
    let defaultsKey = "InspectorSection." + key
    let open = forceSectionsOpen || (preferences.object(forKey: defaultsKey) as? Bool ?? initiallyOpen)
    if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(18, after: last) }
    let toggle = { [weak self] in
      guard let self else { return }
      self.preferences.set(!open, forKey: defaultsKey)
      self.rebuild()
    }
    let disclosure = ActionButton("", toggle)
    disclosure.bezelStyle = .disclosure
    disclosure.setButtonType(.pushOnPushOff)
    disclosure.state = open ? .on : .off
    disclosure.identifier = NSUserInterfaceItemIdentifier("section-" + key)
    disclosure.setAccessibilityLabel(title)
    let label = ActionButton(title, toggle)
    label.isBordered = false
    label.font = .systemFont(ofSize: 14, weight: .semibold)
    label.setAccessibilityElement(false)
    let row = NSStackView(views: [disclosure, label])
    row.orientation = .horizontal
    row.spacing = 2
    add(row)
    if open { body() }
  }

  // MARK: Rows

  @discardableResult func popupRow(
    _ title: String, _ titles: [String], _ selected: Int, help: String? = nil, enabled: Bool = true,
    _ action: @escaping (Int) -> Void
  ) -> ActionPopup {
    let popup = ActionPopup(titles, selected: selected, label: title) { [weak self] i in
      guard let self, self.acceptsEdits else { return }
      action(i)
    }
    popup.toolTip = help
    if let help { popup.setAccessibilityHelp(help) }
    popup.isEnabled = enabled
    let label = inspectorLabel(title, help: help)
    if !enabled { label.textColor = .disabledControlTextColor }
    let row = inspectorRow(label, popup)
    add(row)
    popup.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.58).isActive = true
    return popup
  }
  // An on/off setting. The row records an undo step named `title` and calls `changed(reset:)` after `action`.
  @discardableResult func toggle(
    _ title: String, _ isOn: Bool, reset: Bool = true, help: String? = nil, enabled: Bool = true,
    _ action: @escaping (Bool) -> Void
  ) -> ActionSwitch {
    let control = ActionSwitch(isOn, label: title) { _ in }
    control.actionBlock = { [weak self, weak control] on in
      guard let self, self.acceptsEdits else {
        control?.state = isOn ? .on : .off
        return
      }
      self.checkpoint(title)
      action(on)
      self.changed(reset: reset)
    }
    control.toolTip = help
    if let help { control.setAccessibilityHelp(help) }
    control.isEnabled = enabled
    let label = inspectorLabel(title, help: help)
    if !enabled { label.textColor = .disabledControlTextColor }
    add(inspectorRow(label, control))
    return control
  }
  // A number row. `reset: false` keeps the accumulated samples (display-only settings); `fallback` is the value the
  // reset button restores. See the header for step, scale and live.
  @discardableResult func number(
    _ title: String, _ value: Float, _ range: ClosedRange<Float>, _ fallback: Float,
    reset: Bool = true, entry: ClosedRange<Float>? = nil, integral: Bool = false, step: Float? = nil,
    scale: NumberScale? = nil, live: Bool = true, zeroText: String? = nil, help: String? = nil,
    _ set: @escaping (Float) -> Void
  ) -> NumberControl {
    let control = NumberControl(
      title, value: value, range: range, defaultValue: fallback, entry: entry, integral: integral, step: step,
      scale: scale, live: live, zeroText: zeroText, help: help) { _ in }
    control.update = { [weak self, weak control] v in
      guard let self, self.acceptsEdits else { return }
      // A drag is one undo step, recorded by its first change.
      if control?.continuesDrag != true { self.checkpoint(title) }
      set(v)
      self.changed(reset: reset)
    }
    add(control)
    return control
  }
  @discardableResult func option(
    _ title: String, _ key: WritableKeyPath<StudioOptions, Float>, _ range: ClosedRange<Float>,
    _ fallback: Float, reset: Bool = true, entry: ClosedRange<Float>? = nil, step: Float? = nil,
    scale: NumberScale? = nil, live: Bool = true, zeroText: String? = nil, help: String? = nil
  ) -> NumberControl {
    number(
      title, renderer.options[keyPath: key], range, fallback, reset: reset, entry: entry, step: step, scale: scale,
      live: live, zeroText: zeroText, help: help
    ) { [weak self] in
      self?.renderer.options[keyPath: key] = $0
    }
  }
  // Three values on one line; each field edit (and the reset) is one undo step named `title`.
  @discardableResult func vector(
    _ title: String, _ value: SIMD3<Float>, _ range: ClosedRange<Float>, _ fallback: SIMD3<Float>,
    labels: [String] = ["X", "Y", "Z"], reset: Bool = true, entry: ClosedRange<Float>? = nil, integral: Bool = false,
    step: Float? = nil, help: String? = nil, _ set: @escaping (SIMD3<Float>) -> Void
  ) -> VectorControl {
    let control = VectorControl(
      title, value: value, range: range, defaultValue: fallback, labels: labels, entry: entry, integral: integral,
      step: step, help: help) { [weak self] v in
        guard let self, self.acceptsEdits else { return }
        self.checkpoint(title)
        set(v)
        self.changed(reset: reset)
      }
    add(control)
    return control
  }
  // A colour well for a linear RGB value (the well shows it sRGB-encoded). A colour-panel drag is one undo step.
  @discardableResult func colorRow(
    _ title: String, _ linear: SIMD3<Float>, reset: Bool = true, help: String? = nil,
    _ set: @escaping (SIMD3<Float>) -> Void
  ) -> ActionColor {
    let well = ActionColor(
      NSColor(srgbRed: Self.srgbEncode(linear.x), green: Self.srgbEncode(linear.y), blue: Self.srgbEncode(linear.z),
        alpha: 1), label: title
    ) { [weak self] color in
      guard let self, self.acceptsEdits, let c = color.usingColorSpace(.sRGB) else { return }
      self.checkpoint(title, coalesce: true)
      set(SIMD3(Self.srgbDecode(c.redComponent), Self.srgbDecode(c.greenComponent), Self.srgbDecode(c.blueComponent)))
      self.changed(reset: reset)
    }
    well.toolTip = help
    if let help { well.setAccessibilityHelp(help) }
    well.widthAnchor.constraint(equalToConstant: 44).isActive = true
    well.heightAnchor.constraint(equalToConstant: 22).isActive = true
    add(inspectorRow(inspectorLabel(title, help: help), well))
    return well
  }
  nonisolated static func srgbEncode(_ c: Float) -> CGFloat {
    CGFloat(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
  }
  nonisolated static func srgbDecode(_ c: CGFloat) -> Float {
    let x = Float(c)
    return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
  }
  // A full-width popup without a row label; `label` is its accessibility label.
  func popup(
    _ titles: [String], _ value: Int, label: String? = nil, _ action: @escaping (Int) -> Void
  ) {
    add(
      ActionPopup(titles, selected: value, label: label) { [weak self] i in
        guard let self, self.acceptsEdits else { return }
        action(i)
      })
  }
  // A full-width button. Title case; "…" only when a panel or sheet follows; at most one .primary per page;
  // .destructive last in its section.
  @discardableResult func button(
    _ title: String, style: InspectorButtonStyle = .normal, help: String? = nil, _ action: @escaping () -> Void
  ) -> ActionButton {
    let button = ActionButton(title, style: style, action)
    button.toolTip = help
    if let help { button.setAccessibilityHelp(help) }
    add(button)
    return button
  }
  // Two (or more) short related buttons sharing one row at equal widths.
  func buttonRow(_ buttons: [ActionButton]) {
    let row = NSStackView(views: buttons)
    row.orientation = .horizontal
    row.distribution = .fillEqually
    row.spacing = 8
    add(row)
  }
}
