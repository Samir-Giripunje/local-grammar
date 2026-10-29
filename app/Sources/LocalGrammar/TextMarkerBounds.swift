import ApplicationServices
import Foundation

struct TextMarkerBounds {
    private static let maxSteps = 600

    private let element: AXUIElement
    private let start: AXTextMarker
    private var anchors: [(index: Int, marker: AXTextMarker)]
    private var steps = 0

    init?(element: AXUIElement) {
        guard let fieldRange = Self.parameterized(element, "AXTextMarkerRangeForUIElement", element),
              CFGetTypeID(fieldRange) == AXTextMarkerRangeGetTypeID()
        else { return nil }
        self.element = element
        let fieldStart = AXTextMarkerRangeCopyStartMarker(fieldRange as! AXTextMarkerRange)
        start = Self.textAnchored(fieldStart, in: element)
        anchors = [(0, start)]
    }

    mutating func bounds(of range: NSRange, expecting word: String) -> CGRect? {
        guard let from = marker(at: range.location),
              let to = marker(at: range.location + range.length)
        else { return nil }
        let markerRange = AXTextMarkerRangeCreate(nil, from, to)
        guard let text = Self.parameterized(element, "AXStringForTextMarkerRange", markerRange) as? String,
              text == word,
              let value = Self.parameterized(element, "AXBoundsForTextMarkerRange", markerRange),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    private mutating func marker(at offset: Int) -> AXTextMarker? {
        while let last = anchors.last, last.index < offset, steps < Self.maxSteps {
            guard let next = advance(last.marker, by: "AXNextWordEndTextMarkerForTextMarker"),
                  let index = index(of: next), index > last.index
            else { break }
            anchors.append((index, next))
        }
        guard var anchor = anchors.last(where: { $0.index <= offset }) else { return nil }
        while anchor.index < offset, steps < Self.maxSteps {
            guard let next = advance(anchor.marker, by: "AXNextTextMarkerForTextMarker") else { return nil }
            anchor = (anchor.index + 1, next)
        }
        return anchor.index == offset ? anchor.marker : nil
    }

    private mutating func advance(_ marker: AXTextMarker, by attribute: String) -> AXTextMarker? {
        steps += 1
        guard let next = Self.parameterized(element, attribute, marker),
              CFGetTypeID(next) == AXTextMarkerGetTypeID()
        else { return nil }
        return (next as! AXTextMarker)
    }

    private mutating func index(of marker: AXTextMarker) -> Int? {
        steps += 1
        let range = AXTextMarkerRangeCreate(nil, start, marker)
        return Self.parameterized(element, "AXLengthForTextMarkerRange", range) as? Int
    }

    private static func textAnchored(_ marker: AXTextMarker, in element: AXUIElement) -> AXTextMarker {
        guard let next = parameterized(element, "AXNextTextMarkerForTextMarker", marker),
              CFGetTypeID(next) == AXTextMarkerGetTypeID(),
              let back = parameterized(element, "AXPreviousTextMarkerForTextMarker", next),
              CFGetTypeID(back) == AXTextMarkerGetTypeID()
        else { return marker }
        return back as! AXTextMarker
    }

    private static func parameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }
}
