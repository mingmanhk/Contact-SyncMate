//
//  MacContactsExporter.swift
//  Contact SyncMate
//
//  Created for exporting Mac Contacts to CSV and Excel
//

import Foundation
import AppKit
import Contacts
import Combine
import UniformTypeIdentifiers

/// Handles exporting Mac Contacts to CSV and Excel formats
class MacContactsExporter: ObservableObject {
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportError: String?
    
    private let connector = MacContactsConnector()
    
    enum ExportFormat {
        case csv
        case excel
    }
    
    /// Export Mac Contacts to a CSV file
    /// - Parameter containerIdentifier: Optional specific container/account to export from
    /// - Returns: URL of the saved file, or nil if cancelled
    @MainActor func exportToCSV(from containerIdentifier: String? = nil) async throws -> URL? {
        return try await exportContacts(format: .csv, containerIdentifier: containerIdentifier)
    }
    
    /// Export Mac Contacts to an Excel file
    /// - Parameter containerIdentifier: Optional specific container/account to export from
    /// - Returns: URL of the saved file, or nil if cancelled
    @MainActor func exportToExcel(from containerIdentifier: String? = nil) async throws -> URL? {
        return try await exportContacts(format: .excel, containerIdentifier: containerIdentifier)
    }
    
    /// Export Mac Contacts to the specified format
    /// - Parameters:
    ///   - format: The export format (CSV or Excel)
    ///   - containerIdentifier: Optional specific container/account to export from
    /// - Returns: URL of the saved file, or nil if cancelled
    @MainActor private func exportContacts(format: ExportFormat, containerIdentifier: String?) async throws -> URL? {
        isExporting = true
        exportProgress = 0
        exportError = nil
        
        defer {
            isExporting = false
            exportProgress = 0
        }
        
        // Check authorization
        guard connector.isAuthorized else {
            throw MacContactsError.notAuthorized
        }
        
        // Fetch contacts
        exportProgress = 0.2
        let contacts = try await fetchContacts(from: containerIdentifier)
        
        // Convert to appropriate format
        exportProgress = 0.5
        let fileData: Data
        
        switch format {
        case .csv:
            let csvString = try contactsToCSV(contacts)
            fileData = csvString.data(using: .utf8) ?? Data()
        case .excel:
            fileData = try contactsToExcel(contacts)
        }
        
        // Show save dialog on main thread
        exportProgress = 0.8
        guard let fileURL = showSavePanel(format: format, containerIdentifier: containerIdentifier) else {
            return nil // User cancelled
        }
        
        // Write to file
        try fileData.write(to: fileURL, options: .atomic)
        
        exportProgress = 1.0
        
        return fileURL
    }
    
    private func fetchContacts(from containerIdentifier: String?) async throws -> [CNContact] {
        return try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()

            // Resolve target container: prefer provided ID; else prefer iCloud; else local
            var targetContainer: CNContainer?
            if let identifier = containerIdentifier {
                let containers = try store.containers(matching: nil)
                targetContainer = containers.first(where: { $0.identifier == identifier })
            }

            if targetContainer == nil {
                // Try to get iCloud via connector helper; fall back to recommended container
                if let ic = try? await self.connector.getICloudContainerOnly() {
                    targetContainer = ic
                } else if let recommended = try? await self.connector.getRecommendedContainer() {
                    targetContainer = recommended
                }
            }

            // Always pass a specific container to avoid "All Accounts"
            if let container = targetContainer {
                return try await self.connector.fetchAllContacts(in: container)
            } else {
                // If no container found at all, return empty array rather than querying all accounts
                return []
            }
        }.value
    }
    
    /// Convert contacts to Excel format (XLSX)
    private func contactsToExcel(_ contacts: [CNContact]) throws -> Data {
        // Create XML for Excel workbook
        let worksheetXML = createExcelWorksheet(contacts: contacts)
        let workbookXML = createExcelWorkbook()
        let sharedStringsXML = createSharedStrings()
        let stylesXML = createExcelStyles()
        let contentTypesXML = createContentTypes()
        let relsXML = createRels()
        let workbookRelsXML = createWorkbookRels()
        
        // Create a zip archive (XLSX is a zip file)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Write all XML files
        let xlDir = tempDir.appendingPathComponent("xl")
        try FileManager.default.createDirectory(at: xlDir, withIntermediateDirectories: true)
        
        let worksheetsDir = xlDir.appendingPathComponent("worksheets")
        try FileManager.default.createDirectory(at: worksheetsDir, withIntermediateDirectories: true)
        
        let relsDir = tempDir.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        
        let xlRelsDir = xlDir.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: xlRelsDir, withIntermediateDirectories: true)
        
        try worksheetXML.write(to: worksheetsDir.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)
        try workbookXML.write(to: xlDir.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)
        try sharedStringsXML.write(to: xlDir.appendingPathComponent("sharedStrings.xml"), atomically: true, encoding: .utf8)
        try stylesXML.write(to: xlDir.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)
        try contentTypesXML.write(to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try relsXML.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try workbookRelsXML.write(to: xlRelsDir.appendingPathComponent("workbook.xml.rels"), atomically: true, encoding: .utf8)
        
        // Create zip archive
        let zipURL = tempDir.appendingPathComponent("contacts.xlsx")
        try zipDirectory(at: tempDir, to: zipURL)
        
        // Read the zip file
        let data = try Data(contentsOf: zipURL)
        return data
    }
    
    private func createExcelWorksheet(contacts: [CNContact]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheetData>
        
        """
        
        // Header row (row 1) with bold style
        let headers = [
            "Name", "Given Name", "Middle Name", "Family Name",
            "Name Prefix", "Name Suffix", "Nickname",
            "Email 1 Type", "Email 1 Value",
            "Email 2 Type", "Email 2 Value",
            "Email 3 Type", "Email 3 Value",
            "Phone 1 Type", "Phone 1 Value",
            "Phone 2 Type", "Phone 2 Value",
            "Phone 3 Type", "Phone 3 Value",
            "Address 1 Type", "Address 1 Street", "Address 1 City", "Address 1 State", "Address 1 Postal Code", "Address 1 Country",
            "Organization", "Job Title", "Department",
            "Website 1", "Website 2",
            "Birthday", "Notes",
            "Contact ID"
        ]
        
        xml += "<row r=\"1\">"
        for (index, header) in headers.enumerated() {
            let cellRef = columnLetter(for: index) + "1"
            xml += "<c r=\"\(cellRef)\" t=\"inlineStr\" s=\"1\"><is><t>\(escapeXML(header))</t></is></c>"
        }
        xml += "</row>\n"
        
        // Data rows
        for (rowIndex, contact) in contacts.enumerated() {
            let rowNum = rowIndex + 2 // Start from row 2 (1-indexed)
            xml += "<row r=\"\(rowNum)\">"
            
            var colIndex = 0
            
            // Helper to add a cell
            func addCell(_ value: String) {
                let cellRef = columnLetter(for: colIndex) + "\(rowNum)"
                if !value.isEmpty {
                    xml += "<c r=\"\(cellRef)\" t=\"inlineStr\"><is><t>\(escapeXML(value))</t></is></c>"
                } else {
                    xml += "<c r=\"\(cellRef)\"/>"
                }
                colIndex += 1
            }
            
            // Name
            let displayName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            addCell(displayName)
            addCell(contact.givenName)
            addCell(contact.middleName)
            addCell(contact.familyName)
            addCell(contact.namePrefix)
            addCell(contact.nameSuffix)
            addCell(contact.nickname)
            
            // Emails (up to 3)
            for i in 0..<3 {
                if i < contact.emailAddresses.count {
                    let email = contact.emailAddresses[i]
                    addCell(String(email.label ?? ""))
                    addCell(email.value as String)
                } else {
                    addCell("")
                    addCell("")
                }
            }
            
            // Phones (up to 3)
            for i in 0..<3 {
                if i < contact.phoneNumbers.count {
                    let phone = contact.phoneNumbers[i]
                    addCell(String(phone.label ?? ""))
                    addCell(phone.value.stringValue)
                } else {
                    addCell("")
                    addCell("")
                }
            }
            
            // Address (first one)
            if let address = contact.postalAddresses.first {
                addCell(String(address.label ?? ""))
                addCell(address.value.street)
                addCell(address.value.city)
                addCell(address.value.state)
                addCell(address.value.postalCode)
                addCell(address.value.country)
            } else {
                for _ in 0..<6 { addCell("") }
            }
            
            // Organization
            addCell(contact.organizationName)
            addCell(contact.jobTitle)
            addCell(contact.departmentName)
            
            // URLs (up to 2)
            for i in 0..<2 {
                if i < contact.urlAddresses.count {
                    addCell(contact.urlAddresses[i].value as String)
                } else {
                    addCell("")
                }
            }
            
            // Birthday
            if let birthday = contact.birthday {
                let dateStr = formatDateComponents(birthday)
                addCell(dateStr)
            } else {
                addCell("")
            }
            
            // Notes
            addCell(contact.note)
            
            // Contact identifier
            addCell(contact.identifier)
            
            xml += "</row>\n"
        }
        
        xml += """
        </sheetData>
        </worksheet>
        """
        
        return xml
    }
    
    private func createExcelWorkbook() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
        <sheet name="Contacts" sheetId="1" r:id="rId1"/>
        </sheets>
        </workbook>
        """
    }
    
    private func createSharedStrings() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="0" uniqueCount="0"/>
        """
    }
    
    private func createExcelStyles() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="2">
        <font><sz val="11"/><name val="Calibri"/></font>
        <font><b/><sz val="11"/><name val="Calibri"/></font>
        </fonts>
        <fills count="1">
        <fill><patternFill patternType="none"/></fill>
        </fills>
        <borders count="1">
        <border><left/><right/><top/><bottom/><diagonal/></border>
        </borders>
        <cellXfs count="2">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0"/>
        </cellXfs>
        </styleSheet>
        """
    }
    
    private func createContentTypes() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
        </Types>
        """
    }
    
    private func createRels() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
    }
    
    private func createWorkbookRels() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        </Relationships>
        """
    }
    
    private func columnLetter(for index: Int) -> String {
        var column = ""
        var num = index + 1
        while num > 0 {
            let remainder = (num - 1) % 26
            column = String(UnicodeScalar(65 + remainder)!) + column
            num = (num - 1) / 26
        }
        return column
    }
    
    private func escapeXML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    
    private func formatDateComponents(_ components: DateComponents) -> String {
        var parts: [String] = []
        if let year = components.year {
            parts.append(String(format: "%04d", year))
        }
        if let month = components.month {
            parts.append(String(format: "%02d", month))
        }
        if let day = components.day {
            parts.append(String(format: "%02d", day))
        }
        return parts.isEmpty ? "" : parts.joined(separator: "-")
    }
    
    private func zipDirectory(at sourceURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-X", destinationURL.path, ".", "-x", "*.xlsx"]
        process.currentDirectoryURL = sourceURL
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ExportError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create Excel file"])
        }
    }
    
    /// Convert contacts to CSV format
    private func contactsToCSV(_ contacts: [CNContact]) throws -> String {
        var csv = ""
        
        // CSV Header
        let headers = [
            "Name", "Given Name", "Middle Name", "Family Name",
            "Name Prefix", "Name Suffix", "Nickname",
            "Email 1 Type", "Email 1 Value",
            "Email 2 Type", "Email 2 Value",
            "Email 3 Type", "Email 3 Value",
            "Phone 1 Type", "Phone 1 Value",
            "Phone 2 Type", "Phone 2 Value",
            "Phone 3 Type", "Phone 3 Value",
            "Address 1 Type", "Address 1 Street", "Address 1 City", "Address 1 State", "Address 1 Postal Code", "Address 1 Country",
            "Organization", "Job Title", "Department",
            "Website 1", "Website 2",
            "Birthday", "Notes",
            "Contact ID"
        ]
        csv += headers.map { escapeCSVField($0) }.joined(separator: ",") + "\n"
        
        // Contact rows
        for contact in contacts {
            var row: [String] = []
            
            // Name fields
            let displayName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            row.append(displayName)
            row.append(contact.givenName)
            row.append(contact.middleName)
            row.append(contact.familyName)
            row.append(contact.namePrefix)
            row.append(contact.nameSuffix)
            row.append(contact.nickname)
            
            // Email addresses (up to 3)
            for i in 0..<3 {
                if i < contact.emailAddresses.count {
                    let email = contact.emailAddresses[i]
                    row.append(String(email.label ?? ""))
                    row.append(email.value as String)
                } else {
                    row.append("")
                    row.append("")
                }
            }
            
            // Phone numbers (up to 3)
            for i in 0..<3 {
                if i < contact.phoneNumbers.count {
                    let phone = contact.phoneNumbers[i]
                    row.append(String(phone.label ?? ""))
                    row.append(phone.value.stringValue)
                } else {
                    row.append("")
                    row.append("")
                }
            }
            
            // Address (first one only)
            if let address = contact.postalAddresses.first {
                row.append(String(address.label ?? ""))
                row.append(address.value.street)
                row.append(address.value.city)
                row.append(address.value.state)
                row.append(address.value.postalCode)
                row.append(address.value.country)
            } else {
                row.append(contentsOf: Array(repeating: "", count: 6))
            }
            
            // Organization
            row.append(contact.organizationName)
            row.append(contact.jobTitle)
            row.append(contact.departmentName)
            
            // Websites (up to 2)
            for i in 0..<2 {
                if i < contact.urlAddresses.count {
                    row.append(contact.urlAddresses[i].value as String)
                } else {
                    row.append("")
                }
            }
            
            // Birthday
            if let birthday = contact.birthday {
                row.append(formatDateComponents(birthday))
            } else {
                row.append("")
            }
            
            // Notes
            row.append(contact.note)
            
            // Contact identifier
            row.append(contact.identifier)
            
            csv += row.map { escapeCSVField($0) }.joined(separator: ",") + "\n"
        }
        
        return csv
    }
    
    /// Escape a CSV field (handle quotes, commas, newlines)
    private func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            // Escape quotes by doubling them and wrap in quotes
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }
    
    /// Show a save panel to choose export location
    @MainActor
    private func showSavePanel(format: ExportFormat, containerIdentifier: String?) -> URL? {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Mac Contacts"
        savePanel.message = "Choose a location to save your contacts backup"
        savePanel.nameFieldLabel = "Save as:"
        
        switch format {
        case .csv:
            savePanel.allowedContentTypes = [UTType.commaSeparatedText]
        case .excel:
            // Create custom UTType for Excel files
            let excelType = UTType(filenameExtension: "xlsx") ?? UTType.data
            savePanel.allowedContentTypes = [excelType]
        }
        
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowsOtherFileTypes = false
        
        // Set default filename with timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        
        // Add account name if specific container
        var accountName = "MacContacts"
        if let identifier = containerIdentifier {
            let store = CNContactStore()
            if let containers = try? store.containers(matching: nil),
               let container = containers.first(where: { $0.identifier == identifier }) {
                accountName = container.name.isEmpty ? "MacContacts" : container.name.replacingOccurrences(of: " ", with: "_")
            }
        }
        
        if containerIdentifier == nil {
            // Prefer iCloud name in default filename if available
            let store = CNContactStore()
            if let containers = try? store.containers(matching: nil),
               let iCloud = containers.first(where: { $0.type == .cardDAV && $0.name.lowercased().contains("icloud") }) {
                accountName = iCloud.name.isEmpty ? "iCloud" : iCloud.name.replacingOccurrences(of: " ", with: "_")
            }
        }
        
        switch format {
        case .csv:
            savePanel.nameFieldStringValue = "\(accountName)_\(timestamp).csv"
        case .excel:
            savePanel.nameFieldStringValue = "\(accountName)_\(timestamp).xlsx"
        }
        
        // Set default directory to Documents
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            savePanel.directoryURL = documentsURL
        }
        
        let response = savePanel.runModal()
        return response == .OK ? savePanel.url : nil
    }
    
    /// Show export completion alert
    @MainActor
    func showExportSuccessAlert(fileURL: URL, contactCount: Int) {
        let alert = NSAlert()
        alert.messageText = "Export Successful"
        alert.informativeText = "Exported \(contactCount) contacts to:\n\(fileURL.path)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }
    
    /// Show export error alert
    @MainActor
    func showExportErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

