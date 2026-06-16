import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Generates a QR code image for a string (the tokenized URL) so a phone can
/// scan it instead of typing the address + token.
enum QRCode {
    static func image(for string: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"   // ~15% error correction
        guard let output = filter.outputImage else { return nil }
        // The generator emits a tiny image (1 px per module); scale up with the
        // nearest-neighbour default so the modules stay crisp.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
