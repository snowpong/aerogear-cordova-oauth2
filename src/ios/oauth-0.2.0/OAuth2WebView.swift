//
//  OAuth2WebView.swift
//  DNT Mobilt Medlemskort
//
//  Created by Utvikler on 23.05.15.
//
//

import Foundation

@objc(OAuth2WebView) class OAuth2WebView : UIWebView {
    func webView(webView: UIWebView!, shouldStartLoadWithRequest request: NSURLRequest!, navigationType: UIWebViewNavigationType) -> Bool {
        println(request.URL?.absoluteString)
        return true;
    }

    
}