//
//  CountryFlag.swift
//  Match Point
//
//  Maps tennis-style nationality strings (3-letter IOC codes, 2-letter ISO codes,
//  or full country names) to emoji flags.
//

import Foundation

enum CountryFlag {
    static func emoji(for nationality: String) -> String {
        let trimmed = nationality.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let upper = trimmed.uppercased()
        if upper == "UNK" || upper == "TBD" || upper == "—" { return "" }

        // Already an ISO 3166-1 alpha-2 code
        if upper.count == 2, upper.allSatisfy({ $0.isLetter }) {
            return flagEmoji(fromAlpha2: upper)
        }

        // Common 3-letter IOC / FIFA codes used in tennis broadcasts
        if upper.count == 3, let alpha2 = iocToAlpha2[upper] {
            return flagEmoji(fromAlpha2: alpha2)
        }

        // Try matching by localized country name (English + Portuguese)
        if let alpha2 = nameToAlpha2(trimmed) {
            return flagEmoji(fromAlpha2: alpha2)
        }

        return ""
    }

    private static func flagEmoji(fromAlpha2 code: String) -> String {
        guard code.count == 2 else { return "" }
        let base: UInt32 = 0x1F1E6 - 65 // 'A'
        var scalars = String.UnicodeScalarView()
        for ch in code.uppercased().unicodeScalars where (65...90).contains(ch.value) {
            if let scalar = UnicodeScalar(base + ch.value) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func nameToAlpha2(_ name: String) -> String? {
        let locales = ["en_US_POSIX", "en_US", "pt_BR"]
        let lowered = name.lowercased()
        for identifier in locales {
            let locale = Locale(identifier: identifier)
            for code in Locale.Region.isoRegions.map(\.identifier) {
                if let localized = locale.localizedString(forRegionCode: code)?.lowercased(),
                   localized == lowered {
                    return code
                }
            }
        }
        return nil
    }

    // 3-letter IOC / common tennis-broadcast codes → ISO 3166-1 alpha-2
    private static let iocToAlpha2: [String: String] = [
        "ARG": "AR", "AUS": "AU", "AUT": "AT", "BEL": "BE", "BLR": "BY",
        "BRA": "BR", "BUL": "BG", "CAN": "CA", "CHI": "CL", "CHN": "CN",
        "COL": "CO", "CRO": "HR", "CYP": "CY", "CZE": "CZ", "DEN": "DK",
        "ECU": "EC", "ESP": "ES", "EST": "EE", "FIN": "FI", "FRA": "FR",
        "GBR": "GB", "GEO": "GE", "GER": "DE", "GRE": "GR", "HKG": "HK",
        "HUN": "HU", "INA": "ID", "IND": "IN", "IRL": "IE", "ISR": "IL",
        "ITA": "IT", "JPN": "JP", "KAZ": "KZ", "KOR": "KR", "LAT": "LV",
        "LIE": "LI", "LTU": "LT", "LUX": "LU", "MAR": "MA", "MEX": "MX",
        "MON": "MC", "NED": "NL", "NOR": "NO", "NZL": "NZ", "PER": "PE",
        "PHI": "PH", "POL": "PL", "POR": "PT", "PUR": "PR", "ROU": "RO",
        "RSA": "ZA", "RUS": "RU", "SLO": "SI", "SRB": "RS", "SUI": "CH",
        "SVK": "SK", "SWE": "SE", "THA": "TH", "TPE": "TW", "TUN": "TN",
        "TUR": "TR", "UKR": "UA", "URU": "UY", "USA": "US", "UZB": "UZ",
        "VEN": "VE", "VIE": "VN"
    ]
}
