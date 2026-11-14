import Cocoa

// The inspector's control classes and the row builders every inspector page uses.
final class ActionButton: NSButton {
  var actionBlock: (() -> Void)?
  convenience init(_ title: String, _ action: @escaping () -> Void) {
    self.init(frame: .zero)
    self.title = title
    bezelStyle = .rounded
    target = self
    self.action = #selector(invoke)
    actionBlock = action
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
final class NumberControl: NSStackView {
  let field = NSTextField(), slider = NSSlider()
  var update: ((Float) -> Void)!
  var minimum: Float = 0, maximum: Float = 1
  // Typed values may exceed the slider range up to these limits.
  var entryMinimum: Float = 0, entryMaximum: Float = 1
  // Whole-number controls round typed and slider values and show no decimals.
  var integral = false
  // Text of the last published value; ending editing with it unchanged commits nothing.
  private(set) var displayed = ""
  var onReject: ((String) -> Void)?
  init(
    _ title: String, value: Float, range: ClosedRange<Float>, defaultValue: Float,
    entry: ClosedRange<Float>? = nil, integral: Bool = false, _ action: @escaping (Float) -> Void
  ) {
    super.init(frame: .zero)
    self.integral = integral
    orientation = .vertical
    alignment = .leading
    spacing = 3
    minimum = range.lowerBound
    maximum = range.upperBound
    entryMinimum = min(minimum, entry?.lowerBound ?? minimum)
    entryMaximum = max(maximum, entry?.upperBound ?? maximum)
    update = action
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 6
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 12)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.stringValue = format(value)
    displayed = field.stringValue
    field.alignment = .right
    field.widthAnchor.constraint(equalToConstant: 78).isActive = true
    field.target = self
    field.action = #selector(typed)
    (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
    let reset = ActionButton("↺") { [weak self] in self?.set(defaultValue) }
    reset.toolTip = "Reset \(title)"
    reset.setAccessibilityLabel("Reset \(title)")
    row.addArrangedSubview(label)
    row.addArrangedSubview(field)
    row.addArrangedSubview(reset)
    slider.minValue = Double(minimum)
    slider.maxValue = Double(maximum)
    slider.floatValue = value
    slider.isContinuous = false
    slider.target = self
    slider.action = #selector(slid)
    field.setAccessibilityLabel(title)
    slider.setAccessibilityLabel(title)
    addArrangedSubview(row)
    addArrangedSubview(slider)
    row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    slider.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
  }
  required init?(coder: NSCoder) { fatalError() }
  func set(_ value: Float) {
    guard value.isFinite else {
      NSSound.beep()
      return
    }
    let v = min(entryMaximum, max(entryMinimum, integral ? value.rounded() : value))
    field.stringValue = format(v)
    displayed = field.stringValue
    slider.floatValue = min(maximum, max(minimum, v))
    update(v)
  }
  func format(_ value: Float) -> String { String(format: integral ? "%.0f" : "%.8g", value) }
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
  @objc func typed() {
    // Ending editing (focus loss, inspector rebuild) re-sends the unchanged text.
    guard field.stringValue != displayed else { return }
    guard let value = Self.parse(field.stringValue), value.isFinite else {
      let rejected = field.stringValue
      field.stringValue = displayed
      NSSound.beep()
      onReject?("“\(rejected)” is not a number.")
      return
    }
    set(value)
  }
  @objc func slid() { set(slider.floatValue) }
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

extension StudioController {
  func add(_ v: NSView) {
    if let control = v as? NumberControl, control.onReject == nil {
      control.onReject = { [weak self] message in self?.show(message) }
    }
    stack.addArrangedSubview(v)
    v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
  }
  func text(_ value: String) {
    let label = NSTextField(wrappingLabelWithString: value)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    add(label)
  }
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
  func number(
    _ title: String, _ value: Float, _ range: ClosedRange<Float>, _ fallback: Float,
    reset: Bool = true, entry: ClosedRange<Float>? = nil, integral: Bool = false, _ set: @escaping (Float) -> Void
  ) {
    add(
      NumberControl(title, value: value, range: range, defaultValue: fallback, entry: entry, integral: integral) {
        [weak self] v in
        guard let self, self.acceptsEdits else { return }
        self.checkpoint(title)
        set(v)
        self.changed(reset: reset)
      })
  }
  func option(
    _ title: String, _ key: WritableKeyPath<StudioOptions, Float>, _ range: ClosedRange<Float>,
    _ fallback: Float, reset: Bool = true, entry: ClosedRange<Float>? = nil
  ) {
    number(title, renderer.options[keyPath: key], range, fallback, reset: reset, entry: entry) {
      [weak self] in
      self?.renderer.options[keyPath: key] = $0
    }
  }
  func popup(
    _ titles: [String], _ value: Int, label: String? = nil, _ action: @escaping (Int) -> Void
  ) {
    add(
      ActionPopup(titles, selected: value, label: label) { [weak self] i in
        guard let self, self.acceptsEdits else { return }
        action(i)
      })
  }
  func button(_ title: String, _ action: @escaping () -> Void) { add(ActionButton(title, action)) }
}
