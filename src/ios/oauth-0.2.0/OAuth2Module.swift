/*
* JBoss, Home of Professional Open Source.
* Copyright Red Hat, Inc., and individual contributors
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import Foundation
import UIKit

/**
Notification constants emitted during oauth authorization flow
*/
public let AGAppLaunchedWithURLNotification = "AGAppLaunchedWithURLNotification"
public let AGAppDidBecomeActiveNotification = "AGAppDidBecomeActiveNotification"
public let AGAuthzErrorDomain = "AGAuthzErrorDomain"

/**
The current state that this module is in

- AuthorizationStatePendingExternalApproval:  the module is waiting external approval
- AuthorizationStateApproved:                the oauth flow has been approved
- AuthorizationStateUnknown:                the oauth flow is in unknown state (e.g. user clicked cancel)
*/
enum AuthorizationState {
    case AuthorizationStatePendingExternalApproval
    case AuthorizationStateApproved
    case AuthorizationStateUnknown
}

/**
Parent class of any OAuth2 module implementing generic OAuth2 authorization flow
*/
public class OAuth2Module: NSObject, AuthzModule, UIWebViewDelegate {
    let config: Config
    var http: Http

    var oauth2Session: OAuth2Session
    var applicationLaunchNotificationObserver: NSObjectProtocol?
    var applicationDidBecomeActiveNotificationObserver: NSObjectProtocol?
    var state: AuthorizationState
    var completionHandler: ((AnyObject?, NSError?) -> Void )?
    var webView: UIWebView?
    var toolbar: UIToolbar?
    
    var loginString: String?
    
    var request: NSURLRequest?
    
    var retries: Int?
    
    /**
    Initialize an OAuth2 module

    :param: config                   the configuration object that setups the module
    :param: session                 the session that that module will be bound to
    :param: requestSerializer   the actual request serializer to use when performing requests
    :param: responseSerializer the actual response serializer to use upon receiving a response

    :returns: the newly initialized OAuth2Module
    */
    public required init(config: Config, session: OAuth2Session? = nil, requestSerializer: RequestSerializer = HttpRequestSerializer(), responseSerializer: ResponseSerializer = JsonResponseSerializer()) {
        if (config.accountId == nil) {
            config.accountId = "ACCOUNT_FOR_CLIENTID_\(config.clientId)"
        }
        if (session == nil) {
            self.oauth2Session = TrustedPersistantOAuth2Session(accountId: config.accountId!)
        } else {
            self.oauth2Session = session!
        }
        
        self.config = config
        // TODO use timeout config paramter
        self.http = Http(baseURL: config.baseURL, requestSerializer: requestSerializer, responseSerializer:  responseSerializer)
        self.state = .AuthorizationStateUnknown
    }

    // MARK: Public API - To be overriden if necessary by OAuth2 specific adapter

    /**
    Request an authorization code

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func requestAuthorizationCode(completionHandler: (AnyObject?, NSError?) -> Void) {
        
        // register to receive notification when the application becomes active so we
        // can clear any pending authorization requests which are not completed properly,
        // that is a user switched into the app without Accepting or Cancelling the authorization
        // request in the external browser process.
        applicationDidBecomeActiveNotificationObserver = NSNotificationCenter.defaultCenter().addObserverForName(AGAppDidBecomeActiveNotification, object:nil, queue:nil, usingBlock: { (note: NSNotification!) -> Void in
            // check the state
            if (self.state == .AuthorizationStatePendingExternalApproval) {
                // unregister
                self.stopObserving()
                // ..and update state
                self.state = .AuthorizationStateUnknown;
            }
        })
        
        self.completionHandler = completionHandler
        
        // update state to 'Pending'
        self.state = .AuthorizationStatePendingExternalApproval
        
        let state = NSUUID().UUIDString
        
        // calculate final url
        let params = "?scope=\(config.scope)&redirect_uri=\(config.redirectURL.urlEncode())&client_id=\(config.clientId)&response_type=code&state=\(state)"

        let url = NSURL(string: http.calculateURL(config.baseURL, url:config.authzEndpoint).absoluteString + params)
        
        dispatch_sync(dispatch_get_main_queue(), {
            
            var window = UIApplication.sharedApplication().delegate?.window!
            var webView = UIWebView(frame: CGRectMake(5, 64, window!.frame.width - 10, window!.frame.height - 69))

            webView.delegate = self
            
            var toolbar = UIToolbar(frame: CGRectMake(5, 20, window!.frame.width - 10, 44))
            var items = [UIBarButtonItem]()

            self.webView = webView
            self.toolbar = toolbar

            
            let closeItem = UIBarButtonItem(barButtonSystemItem: UIBarButtonSystemItem.Stop, target: self, action: Selector("closeWebViewWithErrorThrown"))
            
            let spacer = UIBarButtonItem(barButtonSystemItem: UIBarButtonSystemItem.FlexibleSpace, target: nil, action: nil)
            
            let rightSpacer = UIBarButtonItem(barButtonSystemItem: UIBarButtonSystemItem.FixedSpace, target: nil, action: nil)
            
            rightSpacer.width = 7;
            
            
            var label = UILabel(frame: CGRectMake(0, 0, 120, 44))
            if let txt = self.loginString{
                label.text = txt

            }else{
                label.text = "Logg inn"
            }
            
            label.textAlignment = NSTextAlignment.Center
            
            
            items.append(spacer)
            items.append((UIBarButtonItem(customView: label)))
            
            items.append(spacer)
            items.append(closeItem)
            items.append(rightSpacer)
            
            toolbar.setItems(items, animated: true)
            
            window?.addSubview(toolbar)
            window?.addSubview(webView)

            self.request = NSMutableURLRequest(URL: url, cachePolicy: NSURLRequestCachePolicy.ReloadRevalidatingCacheData, timeoutInterval: 10.0)
            
            self.retries = 0
            webView.loadRequest(self.request!)

        })
        
        
    }
    
    public func webView(webView: UIWebView, didFailLoadWithError error: NSError) {
        if error.description.rangeOfString("Could not connect to the server") != nil &&  error.description.rangeOfString("NSErrorFailingURLStringKey=http://localhost:8100/") != nil {
            return
        }
        
        if let retr = self.retries{
            if retr > 3{
                self.completionHandler!(nil, NSError(domain: "OAuth2Module", code: 0, userInfo: ["ConnectionError" : "Couldn't connect to DNT"]))
                
                closeWebView()

            }else{
                self.retries?++
                self.webView?.loadRequest(self.request!)
            }
        }
        
    }

    func closeWebViewWithErrorThrown(){
        
            self.completionHandler!(nil, NSError(domain: "OAuth2Module", code: 0, userInfo: ["WebView Closed" : "WebView was closed by the user"]))
        
        closeWebView()
    }
    func closeWebView(){
        
        if let wv = self.webView{
            wv.removeFromSuperview()
        }
        
        if let tb = self.toolbar{
            tb.removeFromSuperview()
        }
        
        
        
    }
    
    public func webView(webView: UIWebView, shouldStartLoadWithRequest request: NSURLRequest, navigationType: UIWebViewNavigationType) -> Bool {
        self.extractCode(request.URL?.absoluteString, completionHandler: self.completionHandler!)

        return true;
    }
    
    
    /**
    Request to refresh an access token

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func refreshAccessToken(completionHandler: (AnyObject?, NSError?) -> Void) {
        if let unwrappedRefreshToken = self.oauth2Session.refreshToken {
            var paramDict: [String: String] = ["refresh_token": unwrappedRefreshToken, "client_id": config.clientId, "grant_type": "refresh_token"]
            if (config.clientSecret != nil) {
                paramDict["client_secret"] = config.clientSecret!
            }

            http.POST(config.refreshTokenEndpoint!, parameters: paramDict, completionHandler: { (response, error) in
                if (error != nil) {
                    completionHandler(nil, error)
                    return
                }

                if let unwrappedResponse = response as? [String: AnyObject] {
                    let accessToken: String = unwrappedResponse["access_token"] as! String
                    let expiration = unwrappedResponse["expires_in"] as! NSNumber
                    let exp: String = expiration.stringValue
                    
                    self.oauth2Session.saveAccessToken(accessToken, refreshToken: unwrappedRefreshToken, accessTokenExpiration: exp, refreshTokenExpiration: nil)

                    completionHandler(unwrappedResponse["access_token"], nil);
                }
            })
        }
    }

    /**
    Exchange an authorization code for an access token

    :param: code              the 'authorization' code to exchange for an access token
    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func exchangeAuthorizationCodeForAccessToken(code: String, completionHandler: (AnyObject?, NSError?) -> Void) {
        var paramDict: [String: String] = ["code": code, "client_id": config.clientId, "redirect_uri": config.redirectURL, "grant_type":"authorization_code"]

        if let unwrapped = config.clientSecret {
            paramDict["client_secret"] = unwrapped
        }

        http.POST(config.accessTokenEndpoint, parameters: paramDict, completionHandler: {(responseObject, error) in
            if (error != nil) {
                completionHandler(nil, error)
                return
            }
            
            if let unwrappedResponse = responseObject as? [String: AnyObject] {
                let accessToken: String = unwrappedResponse["access_token"] as! String
                let refreshToken: String? = unwrappedResponse["refresh_token"] as? String
                let expiration = unwrappedResponse["expires_in"] as? NSNumber
                let exp: String? = expiration?.stringValue
                
                self.oauth2Session.saveAccessToken(accessToken, refreshToken: refreshToken, accessTokenExpiration: exp, refreshTokenExpiration: nil)
                
                completionHandler(accessToken, nil)
                
                self.closeWebView()

            }else if let ur = responseObject as? NSHTTPURLResponse{
            }
        })
    }

    /**
    Gateway to request authorization access

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func requestAccess(completionHandler: (AnyObject?, NSError?) -> Void) {
        if (self.oauth2Session.accessToken != nil && self.oauth2Session.tokenIsNotExpired()) {
            // we already have a valid access token, nothing more to be done
            completionHandler(self.oauth2Session.accessToken!, nil);
        } else if (self.oauth2Session.refreshToken != nil && self.oauth2Session.refreshTokenIsNotExpired()) {
            // need to refresh token
            self.refreshAccessToken(completionHandler)
        } else {
            // ask for authorization code and once obtained exchange code for access token

            self.requestAuthorizationCode(completionHandler)
        }
    }
    
    /**
    Gateway to provide authentication using the Authorization Code Flow with OpenID Connect
    
    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func login(completionHandler: (AnyObject?, OpenIDClaim?, NSError?) -> Void) {
        
        self.requestAccess { (response:AnyObject?, error:NSError?) -> Void in
            
            if (error != nil) {
                completionHandler(nil, nil, error)
                return
            }
            var paramDict: [String: String] = [:]
            if response != nil {
                paramDict = ["access_token": response! as! String]
            }
            if let userInfoEndpoint = self.config.userInfoEndpoint {

                self.http.GET(userInfoEndpoint, parameters: paramDict, completionHandler: {(responseObject, error) in
                    if (error != nil) {
                        completionHandler(nil, nil, error)
                        return
                    }
                    var openIDClaims: OpenIDClaim?
                    if let unwrappedResponse = responseObject as? [String: AnyObject] {
                        openIDClaims = OpenIDClaim(fromDict: unwrappedResponse)
                    }
                    completionHandler(response, openIDClaims, nil)
                })
            } else {
                completionHandler(nil, nil, NSError(domain: "OAuth2Module", code: 0, userInfo: ["OpenID Connect" : "No UserInfo endpoint available in config"]))
                return
            }
            
        }

    }
    
    /**
    Request to revoke access

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func revokeAccess(completionHandler: (AnyObject?, NSError?) -> Void) {
        // return if not yet initialized
        if (self.oauth2Session.accessToken == nil) {
            return;
        }
        let paramDict:[String:String] = ["token":self.oauth2Session.accessToken!]

        http.POST(config.revokeTokenEndpoint!, parameters: paramDict, completionHandler: { (response, error) in
            if (error != nil) {
                completionHandler(nil, error)
                return
            }

            self.oauth2Session.clearTokens()
            completionHandler(response, nil)
        })
    }
    
    /**
    Request to revoke access
    
    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func clearTokens() {
        // return if not yet initialized
        if (self.oauth2Session.accessToken == nil) {
            return;
        }
        self.oauth2Session.clearTokens()
        self.clearCookies()
    
    }
    
    func clearCookies(){
        var storage : NSHTTPCookieStorage = NSHTTPCookieStorage.sharedHTTPCookieStorage()

        for cookie in storage.cookies  as! [NSHTTPCookie]{
            storage.deleteCookie(cookie)
        }

        NSUserDefaults.standardUserDefaults().synchronize()
        
        for cookie in storage.cookies  as! [NSHTTPCookie]{
            storage.deleteCookie(cookie)
        }

    }

    /**
    Return any authorization fields

    :returns:  a dictionary filled with the authorization fields
    */
    public func authorizationFields() -> [String: String]? {
        if (self.oauth2Session.accessToken == nil) {
            return nil
        } else {
            return ["Authorization":"Bearer \(self.oauth2Session.accessToken!)"]
        }
    }

    /**
    Returns a boolean indicating whether authorization has been granted

    :returns: true if authorized, false otherwise
    */
    public func isAuthorized() -> Bool {
        return self.oauth2Session.accessToken != nil && self.oauth2Session.tokenIsNotExpired()
    }

    // MARK: Internal Methods

    func extractCode(urlString: String?, completionHandler: (AnyObject?, NSError?) -> Void) {
        let url: NSURL? = NSURL(string: urlString!)
        // extract the code from the URL
        let code = self.parametersFromQueryString(url?.query)["code"]
        // if exists perform the exchange
        if (code != nil) {
            self.exchangeAuthorizationCodeForAccessToken(code!, completionHandler: completionHandler)
            // update state
            state = .AuthorizationStateApproved
            self.stopObserving()

        } else if(self.parametersFromQueryString(url?.query)["response_type"] == nil && self.parametersFromQueryString(url?.query?.stringByRemovingPercentEncoding)["response_type"] == nil){

            let error = NSError(domain:AGAuthzErrorDomain, code:0, userInfo:["NSLocalizedDescriptionKey": "User cancelled authorization."])
            completionHandler(nil, error)
            self.stopObserving()

        }
        // finally, unregister
    }

    func parametersFromQueryString(queryString: String?) -> [String: String] {
        var parameters = [String: String]()
        if (queryString != nil) {
            let parameterScanner: NSScanner = NSScanner(string: queryString!)
            var name:NSString? = nil
            var value:NSString? = nil

            while (parameterScanner.atEnd != true) {
                name = nil;
                parameterScanner.scanUpToString("=", intoString: &name)
                parameterScanner.scanString("=", intoString:nil)

                value = nil
                parameterScanner.scanUpToString("&", intoString:&value)
                parameterScanner.scanString("&", intoString:nil)

                if (name != nil && value != nil) {
                    parameters[name!.stringByReplacingPercentEscapesUsingEncoding(NSUTF8StringEncoding)!] = value!.stringByReplacingPercentEscapesUsingEncoding(NSUTF8StringEncoding)
                }
            }
        }

        return parameters;
    }

    deinit {
        self.stopObserving()
    }

    func stopObserving() {
        // clear all observers
        if (applicationLaunchNotificationObserver != nil) {
            NSNotificationCenter.defaultCenter().removeObserver(applicationLaunchNotificationObserver!)
            self.applicationLaunchNotificationObserver = nil;
        }

        if (applicationDidBecomeActiveNotificationObserver != nil) {
            NSNotificationCenter.defaultCenter().removeObserver(applicationDidBecomeActiveNotificationObserver!)
            applicationDidBecomeActiveNotificationObserver = nil
        }
    }
}
