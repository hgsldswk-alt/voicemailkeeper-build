import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

enum ShareCard {
    static let placeholderURL = "https://www.apple.com/app-store/"
    static let topic = "#savevoicemails"

    static var downloadURL: String {
        let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? ""
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return placeholderURL }
        return "https://apps.apple.com/app/id" + id
    }

    static func code(_ link: String, scale: Int = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let quietZone = code.extent.insetBy(dx: -4, dy: -4)
        let image = code.composited(over: CIImage(color: .white).cropped(to: quietZone))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return CIContext().createCGImage(image, from: image.extent)
    }

    static let downloadCode = code(downloadURL)
}

struct CardDesign {
    let caption: String
    let years: String
}

struct CardArt: View {
    let design: CardDesign

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(alignment: .leading, spacing: width * 0.035) {
                Text(design.years).font(.system(size: width * 0.042, weight: .semibold)).foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
                Wave()
                Text(design.caption)
                    .font(.system(size: width * 0.115, design: .serif)).lineLimit(4)
                    .minimumScaleFactor(0.40).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.t("app.name")).font(.system(size: width * 0.044, weight: .bold))
                        Text(ShareCard.topic).font(.system(size: width * 0.04))
                    }
                    .foregroundStyle(Theme.accent)
                    Spacer()
                    if let qr = ShareCard.downloadCode {
                        Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                            .frame(width: width * 0.19, height: width * 0.19)
                    }
                }
            }
            .padding(width * 0.084)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.tint)
            .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
        }
    }
}
