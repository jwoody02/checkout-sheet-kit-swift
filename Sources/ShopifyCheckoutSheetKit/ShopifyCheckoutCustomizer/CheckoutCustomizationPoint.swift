//
//  CheckoutCustomizationPoint.swift
//
//
//  Created by Jordan Wood on 4/15/24.
//

import Foundation
public enum CheckoutCustomizationPoint: String {
    case body = "body"
    case header = "header"
    case mobileHeader = ".header-bar"
    case footer = "footer"
    case button = "button"
    case inputField = ".section__content .field__input"
    case h2 = "h2"
    case h3 = "h3"
    case p = "p"
    case div = "div"
    case payNowButton = ".pay-now-button"
    
    var cssSelector: String {
        return self.rawValue
    }
}
