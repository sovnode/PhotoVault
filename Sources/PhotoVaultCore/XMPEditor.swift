import Foundation

/// Edits an XMP packet as XML: the keyword list (`dc:subject`) and
/// PhotoVault's field (`pv:classifications`) are replaced, and every other
/// element, attribute and value is left exactly as it was — quoting and
/// layout included.
///
/// Not through ImageIO's metadata model: `CGImageMetadataCreateFromXMPData`
/// refuses XMP written with single-quoted attributes, which is valid XML and
/// what ExifTool writes, and a
/// round trip through any model risks dropping what the model doesn't hold.
enum XMPEditor {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let x = "adobe:ns:meta/"

    /// The packet with its keyword list and PhotoVault record lines replaced
    /// (an empty list removes the property). With no packet, a new one.
    static func edited(_ packet: Data?, keywords: [String], recordLines: [String]) throws -> Data {
        let document: XMLDocument
        var nulls = 0
        if let packet {
            let (xml, n) = trimmed(packet)
            nulls = n
            document = try XMLDocument(data: xml, options: [.nodePreserveAll])
        } else {
            document = try XMLDocument(xmlString: """
                <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="\(x)"><rdf:RDF xmlns:rdf="\(rdf)">\
                <rdf:Description rdf:about=""/></rdf:RDF></x:xmpmeta><?xpacket end="w"?>
                """, options: [.nodePreserveAll])
        }
        guard let rdfElement = find(document.rootElement(), uri: rdf, local: "RDF") else {
            throw VaultError.cannotWriteTags("its XMP has no RDF")
        }
        let descriptions = (rdfElement.children ?? []).compactMap { $0 as? XMLElement }
            .filter { $0.uri == rdf && $0.localName == "Description" }
        guard !descriptions.isEmpty else { throw VaultError.cannotWriteTags("its XMP has no description") }
        try setBag(keywords, uri: dc, local: "subject", preferredPrefix: "dc", in: descriptions, rdfElement: rdfElement)
        try setBag(recordLines, uri: PhotoVaultXMP.namespace, local: PhotoVaultXMP.classifications,
                   preferredPrefix: PhotoVaultXMP.prefix, in: descriptions, rdfElement: rdfElement)
        return document.xmlData(options: [.nodePreserveAll]) + Data(count: nulls)
    }

    /// ImageIO ends its packets with a null byte, which isn't XML: set aside
    /// before parsing, and put back after.
    static func trimmed(_ packet: Data) -> (xml: Data, nulls: Int) {
        var n = 0
        while n < packet.count, packet[packet.endIndex - 1 - n] == 0 { n += 1 }
        return (packet.prefix(packet.count - n), n)
    }

    /// Replaces the property's list, adds it, or removes it.
    private static func setBag(_ values: [String], uri: String, local: String, preferredPrefix: String,
                               in descriptions: [XMLElement], rdfElement: XMLElement) throws {
        let existing = descriptions.flatMap { d in
            (d.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.uri == uri && $0.localName == local }
        }
        // Written as an attribute it couldn't be a list; twice, it's ambiguous.
        guard existing.count <= 1,
              !descriptions.contains(where: { d in (d.attributes ?? []).contains { $0.uri == uri && $0.localName == local } })
        else { throw VaultError.cannotWriteTags("its XMP holds \(local) in a form PhotoVault doesn't edit") }
        let rdfPrefix = rdfElement.prefix ?? "rdf"

        if values.isEmpty {
            existing.first?.detach()
            return
        }
        func items(_ prefix: String) -> [XMLElement] {
            values.map { v in
                let li = XMLElement(name: "\(prefix):li", uri: rdf)
                li.stringValue = v
                return li
            }
        }
        if let property = existing.first {
            // Keep the container (normally a Bag) and replace what's in it.
            let container = (property.children ?? []).compactMap { $0 as? XMLElement }.first { $0.uri == rdf }
            guard let container, ["Bag", "Seq", "Alt"].contains(container.localName ?? "") else {
                throw VaultError.cannotWriteTags("its XMP holds \(local) in a form PhotoVault doesn't edit")
            }
            let prefix = container.prefix ?? rdfPrefix
            container.setChildren(items(prefix))
            return
        }
        // New: in the description that already declares the namespace, or
        // the first, under the prefix the file already uses for it.
        let target = descriptions.first { $0.resolvePrefix(forNamespaceURI: uri) != nil } ?? descriptions[0]
        var prefix = target.resolvePrefix(forNamespaceURI: uri) ?? preferredPrefix
        if target.resolvePrefix(forNamespaceURI: uri) == nil {
            // A prefix bound to another namespace here can't be reused.
            var candidate = preferredPrefix, n = 1
            while let bound = target.resolveNamespace(forName: "\(candidate):x"), bound.stringValue != uri {
                candidate = "\(preferredPrefix)\(n)"; n += 1
            }
            prefix = candidate
            target.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
        }
        let property = XMLElement(name: "\(prefix):\(local)", uri: uri)
        let bag = XMLElement(name: "\(rdfPrefix):Bag", uri: rdf)
        bag.setChildren(items(rdfPrefix))
        property.addChild(bag)
        target.addChild(property)
    }

    private static func find(_ element: XMLElement?, uri: String, local: String) -> XMLElement? {
        guard let element else { return nil }
        if element.uri == uri && element.localName == local { return element }
        for child in element.children ?? [] {
            if let found = find(child as? XMLElement, uri: uri, local: local) { return found }
        }
        return nil
    }

    /// Every element, attribute and text value in the packet, one line each,
    /// with its position, leaving out the keyword list and PhotoVault's field
    /// and namespace declarations. Two packets with equal lines say the same
    /// apart from those.
    static func content(_ packet: Data) throws -> [String] {
        let document = try XMLDocument(data: trimmed(packet).xml, options: [])
        var out: [String] = []
        func walk(_ element: XMLElement, _ path: String) {
            let edited = (element.uri == dc && element.localName == "subject")
                || (element.uri == PhotoVaultXMP.namespace && element.localName == PhotoVaultXMP.classifications)
            if edited { return }
            for attribute in element.attributes ?? [] {
                let name = attribute.name ?? ""
                if name == "xmlns" || name.hasPrefix("xmlns:") { continue }
                out.append("\(path) @{\(attribute.uri ?? "")}\(attribute.localName ?? name)=\(attribute.stringValue ?? "")")
            }
            var seen: [String: Int] = [:]
            for child in element.children ?? [] {
                if let e = child as? XMLElement {
                    let name = "{\(e.uri ?? "")}\(e.localName ?? e.name ?? "")"
                    let index = seen[name, default: 0]
                    seen[name] = index + 1
                    walk(e, "\(path)/\(name)[\(index)]")
                } else if child.kind == .text,
                          let text = child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    out.append("\(path) = \(text)")
                }
            }
        }
        if let root = document.rootElement() { walk(root, "") }
        return out
    }
}
