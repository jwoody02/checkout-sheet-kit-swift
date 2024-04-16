//
//  CheckoutStylingBuilder.swift
//
//
//  Created by Jordan Wood on 4/15/24.
//

import Foundation

public class CheckoutStylingBuilder {
    private var styles: [CheckoutCustomizationPoint: String] = [:]
    private var scripts: [String] = []
    
    public init() {}
    
    @discardableResult
    public func setStyle(for point: CheckoutCustomizationPoint, style: String) -> CheckoutStylingBuilder {
        styles[point] = style
        return self
    }

    @discardableResult
    public func addScript(script: String) -> CheckoutStylingBuilder {
        scripts.append(script)
        return self
    }
    
    
    @discardableResult
    public func disableMobileHeader() -> CheckoutStylingBuilder {
        return addStyle(for: .mobileHeader, style: "display: none!important;")
    }
    
    @discardableResult
    public func hideFooter() -> CheckoutStylingBuilder {
        return addStyle(for: .footer, style: "display: none!important;")
    }
    
    @discardableResult
    public func setPageFont(to fontfamily: String) -> CheckoutStylingBuilder {
        let fontString = "font-family: \(fontfamily);"
        return addStyle(for: .body, style: fontString)
        .addStyle(for: .h2, style: fontString)
        .addStyle(for: .h3, style: fontString)
        .addStyle(for: .p, style: fontString)
        .addStyle(for: .div, style: fontString)
    }

    @discardableResult
    public func addStyle(for point: CheckoutCustomizationPoint, style: String) -> CheckoutStylingBuilder {
        if let existingStyle = styles[point] {
            styles[point] = "\(existingStyle) \(style)"
        } else {
            styles[point] = style
        }
        return self
    }
    

    public func build() -> (css: String, js: String) {
        let css = styles.map { key, value in
            return "\(key.cssSelector) { \(value) }"
        }.joined(separator: " ")

        let js = scripts.joined(separator: " ")

        return (css, js)
    }
}
