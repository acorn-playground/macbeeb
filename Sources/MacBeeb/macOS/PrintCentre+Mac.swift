import AppKit
import BeebPrint
import PDFKit

extension PrintCentre {
    /// Prints on the Mac's printer, through the standard print panel.
    func printOnMac(_ job: PrintJob) {
        let data = printout(job).pdf(font: font, title: title(job))
        guard let document = PDFDocumentView.document(data) else { return }
        let info = NSPrintInfo.shared
        info.paperSize = settings.paper.size
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: false)?.run()
    }
}
