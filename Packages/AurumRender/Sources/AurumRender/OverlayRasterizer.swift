import CoreImage
import UIKit
import AurumCore

/// Draws text, stickers and the free-tier watermark into a transparent image
/// the size of the export, using the same normalised layout the Studio shows.
public enum OverlayRasterizer {
    /// Overlay sizes are authored against a 1080 px wide canvas.
    static let referenceWidth: CGFloat = 1080

    public static func render(_ overlays: [Overlay], canvasSize: CGSize, watermark: String?) -> CIImage? {
        let visible = overlays.filter { !$0.isHidden }
        guard !visible.isEmpty || watermark != nil, canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let uiImage = renderer.image { ctx in
            let cg = ctx.cgContext
            let unit = canvasSize.width / referenceWidth
            for overlay in visible {
                cg.saveGState()
                cg.translateBy(x: overlay.center.x * canvasSize.width, y: overlay.center.y * canvasSize.height)
                cg.rotate(by: CGFloat(overlay.rotationDegrees * .pi / 180))
                cg.scaleBy(x: CGFloat(overlay.scale) * unit, y: CGFloat(overlay.scale) * unit)
                cg.setAlpha(CGFloat(overlay.opacity))
                cg.setBlendMode(cgBlendMode(overlay.blendMode))
                switch overlay.content {
                case .text(let text): drawText(text)
                case .sticker(let sticker): drawSticker(sticker)
                }
                cg.restoreGState()
            }
            if let watermark { drawWatermark(watermark, in: canvasSize, context: cg) }
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: Text

    public static func uiFont(for fontID: String, size: CGFloat) -> UIFont {
        let def = OverlayFont.font(id: fontID)
        if let font = UIFont(name: def.postScriptName, size: size) { return font }
        let base = UIFont.systemFont(ofSize: size, weight: .medium)
        var descriptor = base.fontDescriptor
        if def.fallbackDesign == "serif", let serif = descriptor.withDesign(.serif) { descriptor = serif }
        if def.isItalic, let italic = descriptor.withSymbolicTraits(.traitItalic) { descriptor = italic }
        return UIFont(descriptor: descriptor, size: size)
    }

    public static func attributes(for text: TextOverlay) -> [NSAttributedString.Key: Any] {
        let font = uiFont(for: text.fontID, size: CGFloat(text.size))
        let paragraph = NSMutableParagraphStyle()
        switch text.alignment {
        case .leading: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(hex: text.colorHex),
            .paragraphStyle: paragraph
        ]
        switch text.style {
        case .plain, .box, .gradient:
            break
        case .outline:
            attrs[.strokeColor] = UIColor.black
            attrs[.strokeWidth] = -3.0
        case .shadow:
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = CGSize(width: 0, height: 2)
            attrs[.shadow] = shadow
        case .glow:
            let shadow = NSShadow()
            shadow.shadowColor = UIColor(red: 0.96, green: 0.89, blue: 0.75, alpha: 0.9)
            shadow.shadowBlurRadius = 16
            shadow.shadowOffset = .zero
            attrs[.shadow] = shadow
        }
        return attrs
    }

    static func drawText(_ text: TextOverlay) {
        let string = NSAttributedString(string: text.text, attributes: attributes(for: text))
        let bounds = string.boundingRect(with: CGSize(width: referenceWidth * 0.9, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
        let rect = CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height)
        if text.style == .box {
            UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 0.7).setFill()
            UIBezierPath(roundedRect: rect.insetBy(dx: -16, dy: -6), cornerRadius: 6).fill()
        }
        if text.style == .gradient, let ctx = UIGraphicsGetCurrentContext() {
            // Draw the text as a mask, then fill it with an ivory-to-gold gradient.
            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            string.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
            ctx.setBlendMode(.sourceIn)
            let colors = [UIColor(hex: "#F4EFE6").cgColor, UIColor(hex: "#C9A86A").cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            return
        }
        string.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
    }

    // MARK: Stickers

    /// Stickers are drawn 360 px wide at scale 1 on the reference canvas.
    static let stickerBaseWidth: CGFloat = 360

    static func drawSticker(_ sticker: StickerOverlay) {
        guard var image = UIImage(named: "sticker.\(sticker.stickerID)") else { return }
        if let tint = sticker.tintHex {
            image = image.withTintColor(UIColor(hex: tint), renderingMode: .alwaysTemplate)
        }
        let aspect = image.size.height / max(image.size.width, 1)
        let size = CGSize(width: stickerBaseWidth, height: stickerBaseWidth * aspect)
        image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
    }

    // MARK: Watermark

    static func drawWatermark(_ text: String, in size: CGSize, context: CGContext) {
        let unit = size.width / referenceWidth
        let font = uiFont(for: "playfair", size: 26 * unit)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(hex: "#F4EFE6").withAlphaComponent(0.8),
            .kern: 6 * unit
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let s = string.size()
        let margin = 32 * unit
        string.draw(at: CGPoint(x: size.width - s.width - margin, y: size.height - s.height - margin))
    }

    static func cgBlendMode(_ mode: BlendMode) -> CGBlendMode {
        switch mode {
        case .normal: return .normal
        case .screen: return .screen
        case .multiply: return .multiply
        case .overlay: return .overlay
        case .softLight: return .softLight
        case .lighten: return .lighten
        case .darken: return .darken
        }
    }
}

extension UIColor {
    /// Parses "#RRGGBB"; invalid input gives magenta so mistakes are visible.
    public convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&v) else {
            self.init(red: 1, green: 0, blue: 1, alpha: 1)
            return
        }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
